#!/usr/bin/env python3
"""Exercise real exports on an insecure HTTP origin, without exceptions."""
import argparse
import io
import zipfile
import fitz
from PIL import Image
from playwright.sync_api import sync_playwright, expect

parser=argparse.ArgumentParser()
parser.add_argument('--port',type=int,default=3210)
args=parser.parse_args()
doc=fitz.open()
p=doc.new_page(width=144,height=144)
p.insert_text((18,50),'HTTP-ART',fontsize=16)
fixture=doc.tobytes()
with sync_playwright() as pw:
    for name in ['chromium','firefox']:
        options={'headless':True}
        if name=='chromium':
            options['args']=['--host-resolver-rules=MAP pdf-app.test 127.0.0.1']
        else:
            options['firefox_user_prefs']={'network.dns.localDomains':'pdf-app.test'}
        browser=getattr(pw,name).launch(**options)
        page=browser.new_page(accept_downloads=True)
        page.goto(f'http://pdf-app.test:{args.port}/')
        expect(page.get_by_role('button',name='Browse files',exact=True)).to_be_visible()
        assert page.evaluate('window.isSecureContext') is False
        assert page.evaluate('typeof crypto.randomUUID') == 'undefined'
        with page.expect_file_chooser() as chooser:
            page.get_by_role('button',name='Browse files',exact=True).click()
        chooser.value.set_files({'name':'http-art.pdf','mimeType':'application/pdf','buffer':fixture})
        page.get_by_role('button',name='Download images',exact=True).wait_for()
        with page.expect_download(timeout=60000) as download:
            page.get_by_role('button',name='Download images',exact=True).click()
        image=Image.open(download.value.path())
        assert image.format=='PNG' and image.size==(288,288)
        expect(page.get_by_role('button',name='Cancel',exact=True)).to_have_count(0)
        page.get_by_role('button',name='Impose artwork',exact=True).click()
        page.locator('#finished-width').wait_for(timeout=60000)
        page.locator('#finished-width').fill('3')
        page.locator('#finished-height').fill('2')
        page.locator('.sheet-svg image').first.wait_for(timeout=60000)
        for step in ['Quantity & sheet','Arrangement','Bleed']:
            page.get_by_role('button',name='Continue',exact=True).click()
            expect(page.locator('.setup-stepper button[aria-current=step]')).to_have_text(step)
        with page.expect_download(timeout=60000) as download:
            page.get_by_role('button',name='Download imposed PDF',exact=True).click()
        with fitz.open(download.value.path()) as result:
            assert len(result)==1 and tuple(result[0].rect)[2:]==(864,1296)
            assert 'HTTP-ART' in result[0].get_text()
        print(name+': insecure HTTP origin + raster and imposed exports passed',flush=True)
        browser.close()
