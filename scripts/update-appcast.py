#!/usr/bin/env python3
"""Prepare a signed update feed from the packaged archive. Does not publish."""
import email.utils
import json
import os
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
directory = pathlib.Path(sys.argv[1]).resolve()
tool = pathlib.Path(sys.argv[2]) / "bin/sign_update"
key = pathlib.Path(os.environ.get("SWITCHBOARD_UPDATE_SIGNING_KEY", "~/.config/switchboard/update-signing-key")).expanduser()
assert key.is_file(), "Set SWITCHBOARD_UPDATE_SIGNING_KEY to the private seed for config/update-public-key.txt"
assert key.stat().st_mode & 0o077 == 0, "Signing seed must have owner-only permissions"
subprocess.run(["swift", str(root / "scripts/update-key.swift"), str(key), str(root / "config/update-public-key.txt")], check=True)
values = dict(re.findall(r"^(SWITCHBOARD_[A-Z]+)=([0-9.]+)$", (root / "scripts/version.sh").read_text(), re.M))
version, build = values["SWITCHBOARD_VERSION"], values["SWITCHBOARD_BUILD"]
manifest = json.loads((directory / "release.json").read_text())
asset = next(a for a in manifest["assets"] if a["name"].endswith(".zip"))
archive = directory / asset["name"]
signature = subprocess.check_output([str(tool), "--ed-key-file", str(key), "-p", str(archive)], text=True).strip()
subprocess.run([str(tool), "--ed-key-file", str(key), "--verify", str(archive), signature], check=True)
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Switchboard updates"
ET.SubElement(channel, "link").text = "https://switchboard.quasa0.com/"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Switchboard {version}"
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, "enclosure", {"url": asset["url"], "length": str(archive.stat().st_size),
    "type": "application/octet-stream", f"{{{sparkle}}}version": build,
    f"{{{sparkle}}}shortVersionString": version, f"{{{sparkle}}}edSignature": signature})
ET.indent(rss)
destination = directory / "appcast.xml"
destination.write_bytes(ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n")
subprocess.run([str(tool), "--ed-key-file", str(key), str(destination)], check=True)
subprocess.run([str(tool), "--ed-key-file", str(key), "--verify", str(destination)], check=True)
(root / "site/appcast.xml").write_bytes(destination.read_bytes())
print(f"Prepared signed feed for {version} build {build}. No upload or deployment.")
