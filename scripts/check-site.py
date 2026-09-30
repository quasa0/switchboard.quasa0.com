#!/usr/bin/env python3
"""Offline publication checks: links, release contracts, and privacy boundaries."""
import hashlib
import json
import pathlib
import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / 'site'

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.h1, self.images = [], [], 0, []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        if tag == 'h1':
            self.h1 += 1
        if tag == 'img':
            self.images.append(attrs)
        for key in ('href', 'src'):
            if key in attrs:
                self.links.append(attrs[key])

page = Page()
html = (SITE / 'index.html').read_text()
page.feed(html)
assert page.h1 == 1, 'Use one descriptive h1'
assert len(page.ids) == len(set(page.ids)), 'Duplicate HTML id'
assert all(i.get('alt') and i.get('width') and i.get('height') for i in page.images), 'Image metadata missing'
for url in page.links:
    parsed = urlsplit(url)
    assert parsed.scheme in ('', 'https'), f'Unsafe link scheme: {url}'
    if parsed.scheme:
        continue
    if parsed.path and parsed.path != '/':
        assert (SITE / unquote(parsed.path.lstrip('/'))).is_file(), f'Missing site asset: {url}'
    if parsed.fragment:
        assert parsed.fragment in page.ids, f'Broken anchor: {url}'
for css_asset in re.findall(r"url\(['\"]?(/[^)'\"]+)", (SITE / 'style.css').read_text()):
    assert (SITE / css_asset.lstrip('/')).is_file(), f'Missing CSS asset: {css_asset}'
version = re.search(r'^SWITCHBOARD_VERSION=([0-9.]+)$', (ROOT / 'scripts/version.sh').read_text(), re.M)[1]
manifest = json.loads((SITE / 'release.json').read_text())
feed = ET.parse(SITE / 'appcast.xml')
enclosure = feed.find('./channel/item/enclosure')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert enclosure is not None
assert enclosure.get(sparkle + 'shortVersionString') == version
build = re.search(r'^SWITCHBOARD_BUILD=([0-9]+)$', (ROOT / 'scripts/version.sh').read_text(), re.M)[1]
assert enclosure.get(sparkle + 'version') == build
assert re.fullmatch(r'[A-Za-z0-9+/]{86}==', enclosure.get(sparkle + 'edSignature', ''))
assert b'Sparkle' in (SITE / 'appcast.xml').read_bytes(), 'Signed feed metadata missing'
zip_asset = next(a for a in manifest['assets'] if a['name'].endswith('.zip'))
assert enclosure.get('url') == zip_asset['url']
assert int(enclosure.get('length')) == zip_asset['bytes']
assert manifest['version'] == version
assert manifest['minimumMacOS'] == '14.0'
assert set(manifest['architectures']) == {'arm64', 'x86_64'}
assert manifest['signing'] == 'ad-hoc' and manifest['notarized'] is False
assert {a['name'] for a in manifest['assets']} == {f'Switchboard-{version}-universal.{s}' for s in ('zip','dmg')}
for asset in manifest['assets']:
    assert re.fullmatch('[a-f0-9]{64}', asset['sha256'])
    assert asset['bytes'] > 100000
    expected = f"https://github.com/quasa0/switchboard/releases/download/v{version}/{asset['name']}"
    assert asset['url'] == expected
    assert expected in page.links, f'Missing download link: {expected}'
    local = ROOT / 'dist/releases' / version / asset['name']
    if local.exists():
        assert hashlib.sha256(local.read_bytes()).hexdigest() == asset['sha256'], 'Stale release manifest'
for path in (ROOT/'README.md', SITE/'index.html', SITE/'install.md'):
    for linked_version in re.findall(r'(?:/download/v|/tag/v|--detach v)([0-9.]+)', path.read_text()):
        assert linked_version == version, f'Stale version in {path.name}'
for path in SITE.rglob('*'):
    if not path.is_file() or '.vercel' in path.parts:
        continue
    assert path.suffix not in ('.pem', '.key', '.p12', '.p8', '.log', '.har'), f'Private file type in site: {path.name}'
    if path.suffix in ('.html','.css','.js','.md','.txt','.json','.xml','.svg'):
        text = path.read_text()
        assert '/Users/' not in text, f'Personal path in {path.name}'
        assert not re.search(r'[\w.+-]+@(?:gmail|icloud|outlook)\.com', text), f'Personal email in {path.name}'
assert (SITE/'fonts/OFL.txt').is_file(), 'Font license missing'
assert 'posthog' not in html.lower(), 'Do not copy source-site analytics'
print(f'PASS: local assets, anchors, accessibility metadata, version {version}, checksums, and publication boundaries')
