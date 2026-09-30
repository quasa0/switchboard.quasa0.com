#!/usr/bin/env python3
"""Exercise Sparkle with isolated demo apps, ephemeral keys, and a loopback feed."""
import functools
import http.server
import json
import os
import pathlib
import plistlib
import re
import signal
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
tools = pathlib.Path(os.environ["SWITCHBOARD_SPARKLE_TOOLS"])
(root / "artifacts/updater").mkdir(parents=True, exist_ok=True)
base = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=root / "artifacts/updater"))
fixture_ids = []

def run(*args):
    return subprocess.check_output([str(a) for a in args], cwd=root, stderr=subprocess.STDOUT, text=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(base)))
thread = threading.Thread(target=server.serve_forever)
thread.start()
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)

try:
    key = base / "private-seed"
    public = base / "public-key"
    run("swift", "scripts/update-key.swift", key, public)
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    development = re.search(r'\) ([A-F0-9]{40}) "Apple Development:', identities)
    modes = ["no-update", "check-error", "unsigned-feed", "unsupported-os", "invalid-signature", "cancel", "install"]
    if development:
        modes.append("development-install")
    for mode in modes:
        case = base / mode
        case.mkdir()
        app = case / "Switchboard.app"
        run("ditto", root / "dist/Switchboard.app", app)
        plist_path = app / "Contents/Info.plist"
        plist = plistlib.loads(plist_path.read_bytes())
        plist.update(CFBundleIdentifier="com.quasa0.switchboard.update-test." + uuid.uuid4().hex,
                     CFBundleVersion="1", CFBundleShortVersionString="0.0.1",
                     SUPublicEDKey=public.read_text().strip(),
                     SwitchboardUpdateTestMarker=str(case / "relaunched"))
        fixture_ids.append(plist["CFBundleIdentifier"])
        plist_path.write_bytes(plistlib.dumps(plist))
        run("bash", "scripts/sign-app.sh", app, development[1] if mode == "development-install" else "-")
        incoming = case / "incoming"
        incoming.mkdir()
        new_app = incoming / "Switchboard.app"
        run("ditto", app, new_app)
        new_plist = {**plist, "CFBundleVersion": "2", "CFBundleShortVersionString": "0.0.2"}
        (new_app / "Contents/Info.plist").write_bytes(plistlib.dumps(new_plist))
        run("bash", "scripts/sign-app.sh", new_app, "-")
        archive = case / "update.zip"
        run("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", new_app, archive)
        signature = run(tools / "bin/sign_update", "--ed-key-file", key, "-p", archive).strip()
        if mode == "invalid-signature":
            signature = "A" * 86 + "=="
        feed = case / "appcast.xml"
        if mode == "check-error":
            feed.write_text("invalid XML")
        else:
            rss = ET.Element("rss", version="2.0")
            channel = ET.SubElement(rss, "channel")
            ET.SubElement(channel, "title").text = "Switchboard isolated updater fixture"
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = "Synthetic update"
            ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = "99.0" if mode == "unsupported-os" else "14.0"
            ET.SubElement(item, "enclosure", {"url": f"http://127.0.0.1:{server.server_port}/{mode}/update.zip",
                "length": str(archive.stat().st_size), "type": "application/octet-stream",
                f"{{{sparkle}}}version": "1" if mode == "no-update" else "2",
                f"{{{sparkle}}}shortVersionString": "0.0.2", f"{{{sparkle}}}edSignature": signature})
            feed.write_bytes(ET.tostring(rss, encoding="utf-8", xml_declaration=True))
            if mode != "unsigned-feed":
                run(tools / "bin/sign_update", "--ed-key-file", key, feed)
        report = case / "report.json"
        log = case / "process.log"
        with log.open("w") as output:
            process = subprocess.Popen([str(app / "Contents/MacOS/Switchboard"), "--demo", "--update-smoke",
                f"http://127.0.0.1:{server.server_port}/{mode}/appcast.xml", str(report), mode],
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                result = process.wait(timeout=100)
                assert result == 0, f"{mode}: fixture failed; see {log}"
                data = json.loads(report.read_text())
                assert data["credentialAccess"] is False
                expected = {"no-update": "idle", "check-error": "error", "unsigned-feed": "error", "unsupported-os": "idle", "invalid-signature": "available",
                            "cancel": "ready", "install": "ready", "development-install": "ready"}[mode]
                assert data["status"] == expected, data
                deadline = time.monotonic() + 25
                while mode.endswith("install") and not (case / "relaunched").exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if mode.endswith("install"):
                    assert (case / "relaunched").read_text() == "2", "New app did not relaunch in demo mode"
                elif mode == "cancel":
                    time.sleep(2)
                    assert plistlib.loads(plist_path.read_bytes())["CFBundleVersion"] == "1", "Ordinary quit installed the update"
                    assert not (case / "relaunched").exists(), "Ordinary quit unexpectedly relaunched"
                run("codesign", "--verify", "--deep", "--strict", app)
                print(f"PASS: {mode}; no account engine or credential access", flush=True)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
    print(f"Artifacts: {base}", flush=True)
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    (base / "private-seed").unlink(missing_ok=True)
    # Sparkle relaunches outside the original process group. Track those fixture
    # helpers by unique bundle IDs/paths, and do not leave an installer behind.
    def owned_pids():
        rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines()
        return [int(row.split(None, 1)[0]) for row in rows
                if str(base) in row or any(identity in row for identity in fixture_ids)]
    deadline = time.monotonic() + 10
    while owned_pids() and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid in owned_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.2)
    for pid in owned_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    assert not owned_pids(), "Updater fixture helper did not stop"
    for identity in fixture_ids:
        assert re.fullmatch(r"com\.quasa0\.switchboard\.update-test\.[a-f0-9]{32}", identity)
        subprocess.run(["defaults", "delete", identity], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (pathlib.Path.home() / "Library/Preferences" / (identity + ".plist")).unlink(missing_ok=True)
        cache = pathlib.Path.home() / "Library/Caches" / identity
        if cache.is_symlink():
            cache.unlink()
        elif cache.exists():
            shutil.rmtree(cache)
