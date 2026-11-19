#!/usr/bin/env python3
"""Exercise Yard Signs against a running local server (Playwright + PyMuPDF)."""
import argparse
import re
from tempfile import TemporaryDirectory
from pathlib import Path

import fitz
from playwright.sync_api import expect, sync_playwright


def run(page, base, directory):
    def upload(button, filename, labels):
        path = directory / filename
        with fitz.open() as pdf:
            for label in labels:
                pdf.new_page(width=216, height=144).insert_text((20, 72), label)
            pdf.save(path)
        with page.expect_file_chooser() as chooser:
            page.get_by_role('button', name=button, exact=True).click()
        chooser.value.set_files(path)

    def proof(number):
        return page.get_by_role('img', name=f'Output proof, page {number}', exact=True)

    probes, jobs, exports = [], [], []

    def connector(route):
        req = route.request
        assert req.headers['x-pdf-tools'] == 'versaworks'
        if req.url.endswith('/status'):
            assert req.method == 'GET'
            probes.append(req.url)
            route.fulfill(json={'available': len(probes) > 1})
        else:
            assert req.url.endswith('/jobs') and req.method == 'POST'
            assert req.headers['content-type'] == 'application/pdf'
            jobs.append(req.post_data_buffer)
            if len(jobs) == 1:
                route.fulfill(status=201, json={'filename': 'queued.pdf'})
            else:
                route.abort()  # Lost acknowledgement; must not replay.

    def exported(response):
        if response.url.endswith('/api/yard-sign'):
            assert response.ok, (response.status, response.text())
            exports.append(response.body())

    page.route('http://127.0.0.1:43127/**', connector)
    page.on('response', exported)
    # Model the production path-stripping proxy. A root-absolute request
    # must not accidentally succeed against the local backend's root API.
    origin = base.rstrip('/')
    prefix = origin + '/pdftools/'
    page.route(origin + '/**', lambda route: route.fallback() if route.request.url.startswith(prefix) else route.abort())
    page.route(prefix + '**', lambda route: route.continue_(
        url=origin + '/' + route.request.url[len(prefix):]) if not route.request.is_navigation_request()
        else route.fulfill(response=route.fetch(url=origin + '/')))
    page.goto(prefix)
    yard = page.get_by_role('button', name=re.compile('Yard Signs'))
    expect(yard).to_be_visible()
    assert not probes and not jobs
    yard.click()
    page.get_by_role('button', name='Retry detection').click()
    expect(page.get_by_text('VersaWorks is available.')).to_be_visible()
    page.get_by_role('button', name=re.compile('Extract pages')).click()
    expect(page.get_by_text('VersaWorks is available.')).to_have_count(0)
    assert len(probes) == 2
    yard.click()
    expect(page.get_by_text('VersaWorks is available.')).to_be_visible()
    assert len(probes) == 3 and not jobs
    upload('Browse files', 'pages.pdf', ['Front', 'Back'])
    expect(proof(1)).to_be_visible()
    image = page.locator('.yard-proof-stage image')
    first = image.evaluate('el => el.href.baseVal')
    page.get_by_role('button', name='Next page').click()
    expect(proof(2)).to_be_visible()
    assert image.evaluate('el => el.href.baseVal') != first
    page.get_by_role('button', name='Previous page').click()
    expect(proof(1)).to_be_visible()
    assert image.evaluate('el => el.href.baseVal') == first

    page.locator('#yard-size').select_option('custom')
    page.locator('#yard-width').fill('')
    expect(image).to_have_count(0)
    expect(page.get_by_role('button', name='Download PDF')).to_be_disabled()
    send = page.get_by_role('button', name='Send to VersaWorks')
    expect(send).to_be_disabled()
    route = '**/api/yard-sign/sources/*/previews'
    page.route(route, lambda req: req.fulfill(status=400, body='Test proof failure'))
    page.locator('#yard-width').fill('14.25')
    expect(page.get_by_text('Proof unavailable.', exact=False)).to_be_visible()
    expect(image).to_have_count(0)
    page.unroute(route)
    page.get_by_role('button', name='Retry proof').click()
    expect(proof(1)).to_be_visible()
    expect(proof(1)).to_have_attribute('viewBox', '0 0 14.75 18.5')
    for mode in ['Fill', 'Stretch']:
        page.get_by_role('radio', name=mode, exact=True).check()
        expect(proof(1)).to_be_visible()
    with page.expect_request(lambda req: req.method == 'DELETE' and '/gang-up/sources/' in req.url):
        upload('Replace PDF', 'single.pdf', ['Replacement'])
    expect(proof(1)).to_be_visible()
    expect(page.get_by_text('Page 1 of 1', exact=True)).to_be_visible()
    expect(page.get_by_role('button', name='Next page')).to_have_count(0)
    with page.expect_download() as downloaded:
        page.get_by_role('button', name='Download PDF').click()
    assert downloaded.value.path().read_bytes() == exports[0]
    assert not jobs and len(exports) == 1
    send.evaluate('button => { button.click(); button.click(); }')
    expect(page.get_by_text('Sent to VersaWorks: queued.pdf')).to_be_visible()
    assert jobs == exports[1:] and len(jobs) == 1
    assert jobs[0].startswith(b'%PDF-') and jobs[0] != (directory / 'single.pdf').read_bytes()
    send.click()
    expect(page.get_by_text('Delivery not confirmed.', exact=False)).to_be_visible()
    expect(send).to_be_disabled()
    page.get_by_role('button', name='Retry detection').click()
    expect(send).to_be_enabled()
    assert len(jobs) == 2 and jobs == exports[1:]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='http://localhost:3001')
    parser.add_argument('--chromium')
    args = parser.parse_args()
    with sync_playwright() as pw, TemporaryDirectory() as tmp:
        browser = pw.chromium.launch(executable_path=args.chromium)
        run(browser.new_page(), args.base, Path(tmp))
        browser.close()
    print('Yard Signs proof checks passed.')
