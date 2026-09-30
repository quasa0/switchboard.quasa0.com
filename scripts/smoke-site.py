#!/usr/bin/env python3
"""Check the deployed page, assets, agent guide, and real release download bytes."""
import hashlib
import json
import pathlib
import sys
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

base = sys.argv[1].rstrip('/') + '/' if len(sys.argv) > 1 else 'https://switchboard.quasa0.com/'
class Assets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ('script', 'img') and attrs.get('src', '').startswith('/'):
            self.paths.add(attrs['src'])
        if tag == 'link' and attrs.get('rel') in ('stylesheet','icon','preload'):
            self.paths.add(attrs['href'])

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Switchboard-release-smoke/1.0'})
    with urllib.request.urlopen(req, timeout=45) as response:
        assert response.status == 200, f'{url}: HTTP {response.status}'
        data = response.read()
        assert data, f'{url}: empty body'
        return data, response.headers

html, headers = fetch(base)
assert b'All your AI accounts.' in html and b'id="install"' in html, 'Wrong or incomplete entry page'
page = Assets()
page.feed(html.decode())
for path in sorted(page.paths | {'/install.md','/llms.txt','/release.json','/appcast.xml','/fonts/OFL.txt','/robots.txt','/sitemap.xml'}):
    data, asset_headers = fetch(urljoin(base, path))
    if path.endswith('.js'):
        assert 'javascript' in asset_headers.get('Content-Type',''), 'Wrong script MIME'
    if path.endswith('.css'):
        assert 'text/css' in asset_headers.get('Content-Type',''), 'Wrong stylesheet MIME'
    if path.endswith('.png'):
        assert data.startswith(b'\x89PNG'), 'Wrong screenshot bytes'
    if path == '/install.md':
        assert b'Verify and report' in data and b'Do not use sudo' in data, 'Wrong agent guide'
        assert 'text/plain' in asset_headers.get('Content-Type',''), 'Agent instructions are not plain text'
    if path == '/release.json':
        manifest = json.loads(data)
    local = pathlib.Path(__file__).resolve().parent.parent / 'site' / path.lstrip('/')
    assert data == local.read_bytes(), f'Deployed asset differs from repository: {path}'
print('PASS: entry, CSS, JavaScript, image, font, license, agent docs, and metadata', flush=True)
expected = json.loads((pathlib.Path(__file__).resolve().parent.parent/'site/release.json').read_text())
assert manifest == expected, 'Deployed release manifest differs from repository'
if urlsplit(base).hostname not in ('127.0.0.1','localhost'):
    assert "default-src 'none'" in headers.get('Content-Security-Policy',''), 'Missing CSP'
    assert headers.get('X-Content-Type-Options') == 'nosniff'
for asset in manifest['assets']:
    data, _ = fetch(asset['url'])
    assert len(data) == asset['bytes'], f"Wrong asset size: {asset['name']}"
    assert hashlib.sha256(data).hexdigest() == asset['sha256'], f"Checksum mismatch: {asset['name']}"
    print(f"PASS: published {asset['name']} checksum ({len(data)} bytes)", flush=True)
print('PASS: deployed installation path. This static site has no authenticated API or realtime service.')
