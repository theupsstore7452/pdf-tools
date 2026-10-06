#!/usr/bin/env python3
"""Build/check a disposable container; never mounts persistent shop data."""
import argparse
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--engine', choices=['docker', 'podman'], default='docker')
parser.add_argument('--image', default='pdf-tools-elm:validation')
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
repository = pathlib.Path(__file__).resolve().parent.parent

def engine(*command, **kwargs):
    return subprocess.run([args.engine, *command], check=True, text=True, **kwargs)

if not args.skip_build:
    engine('build', '--tag', args.image, str(repository))
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
name = 'pdf-tools-elm-validation-' + uuid.uuid4().hex
url = f'http://127.0.0.1:{port}'
engine('run', '--detach', '--rm', '--name', name, '--publish', f'127.0.0.1:{port}:3000', args.image)
try:
    for attempt in range(200):
        try:
            with urllib.request.urlopen(url+'/health', timeout=1) as response:
                if response.read() == b'ok':
                    break
        except OSError:
            time.sleep(.1)
    else:
        raise RuntimeError('Container did not become healthy')
    with urllib.request.urlopen(url) as response:
        html = response.read().decode()
    assets = set(re.findall(r'assets/[a-f0-9]{16}/(?:elm\.js|bridge\.js|app\.css)', html))
    assert len(assets) == 3, assets
    for asset in assets:
        request = urllib.request.Request(url+'/'+asset, headers={'Accept-Encoding':'gzip'})
        with urllib.request.urlopen(request) as response:
            assert response.headers.get('Content-Encoding') == 'gzip', asset
            assert len(response.read()) > 100, asset
    subprocess.run([sys.executable, str(repository/'scripts/elm-browser-acceptance.py'), '--url', url], check=True)
    subprocess.run([sys.executable, str(repository/'scripts/elm-http-acceptance.py'), '--port', str(port)], check=True)
    # Real deployed-file failure: restore before asking the user-facing Retry.
    bundle = '/app/frontend/dist/'+next(asset for asset in assets if asset.endswith('/elm.js'))
    def move_bundle(remove):
        for suffix in ['', '.gz']:
            path=bundle+suffix
            engine('exec',name,'mv',path if remove else path+'.missing',path+'.missing' if remove else path)
    move_bundle(True)
    try:
        with sync_playwright() as pw:
            for browser_type in [pw.chromium, pw.firefox]:
                browser = browser_type.launch(headless=True)
                page = browser.new_page()
                page.goto(url)
                expect(page.locator('#startup-retry')).to_be_visible()
                move_bundle(False)
                page.locator('#startup-retry').click()
                expect(page.get_by_role('button',name='Browse files',exact=True)).to_be_visible()
                move_bundle(True)
                browser.close()
    finally:
        move_bundle(False)
    print('Container assets, output inspection, HTTP and deployed-file recovery passed')
finally:
    engine('logs', name)
    engine('rm', '--force', name)
