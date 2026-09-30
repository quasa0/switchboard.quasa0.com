#!/usr/bin/env python3
"""Verify the actual public signed feed/archive with Sparkle in a credential-free fixture."""
import functools
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
identity = "com.quasa0.switchboard.update-test." + uuid.uuid4().hex
base = root / "artifacts/updater" / ("public-" + uuid.uuid4().hex)
base.mkdir(parents=True)
server = None
thread = None
process = None

def owned_pids():
    rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines()
    return [int(row.split(None, 1)[0]) for row in rows if str(base) in row or identity in row]

try:
    request = urllib.request.Request("https://switchboard.quasa0.com/appcast.xml",
                                     headers={"User-Agent": "Switchboard-public-updater-smoke/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        assert response.status == 200
        feed = response.read(131_073)
    assert len(feed) <= 131_072 and feed == (root / "site/appcast.xml").read_bytes()
    enclosure = ET.fromstring(feed).find("channel/item/enclosure")
    assert enclosure is not None
    manifest = json.loads((root / "site/release.json").read_text())
    archive = next(asset for asset in manifest["assets"] if asset["name"].endswith(".zip"))
    assert enclosure.attrib["url"] == archive["url"]
    build = int(enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}version"])
    (base / "appcast.xml").write_bytes(feed)  # Unmodified bytes retain the public feed signature.
    app = base / "Switchboard.app"
    subprocess.run(["ditto", str(root / "dist/Switchboard.app"), str(app)], check=True)
    plist_path = app / "Contents/Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    assert plist["SUPublicEDKey"] == (root / "config/update-public-key.txt").read_text().strip()
    plist.update(CFBundleIdentifier=identity, CFBundleVersion=str(build - 1),
                 SwitchboardUpdateTestMarker=str(base / "must-not-relaunch"))
    plist_path.write_bytes(plistlib.dumps(plist))
    subprocess.run(["bash", "scripts/sign-app.sh", str(app), "-"], cwd=root, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(base)))
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    report = base / "report.json"
    with (base / "smoke.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/Switchboard"), "--demo", "--update-smoke",
                                    f"http://127.0.0.1:{server.server_port}/appcast.xml", str(report), "cancel"],
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        assert process.wait(timeout=150) == 0, "Public update did not become ready"
    result = json.loads(report.read_text())
    assert result["credentialAccess"] is False and result["status"] == "ready"
    assert result["version"] == manifest["version"]
    assert {"available", "downloading", "ready"}.issubset(result["transitions"])
    assert not (base / "must-not-relaunch").exists()
    print(f"PASS: public signed feed and actual GitHub archive reached ready through Sparkle; version {result['version']}; no credentials or installation. Evidence: {base}", flush=True)
finally:
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    if server is not None:
        server.shutdown()
        server.server_close()
    if thread is not None:
        thread.join()
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
    assert not owned_pids(), "Public updater fixture left a helper running"
    subprocess.run(["defaults", "delete", identity], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (pathlib.Path.home() / "Library/Preferences" / (identity + ".plist")).unlink(missing_ok=True)
    cache = pathlib.Path.home() / "Library/Caches" / identity
    if cache.is_symlink():
        cache.unlink()
    elif cache.exists():
        shutil.rmtree(cache)
