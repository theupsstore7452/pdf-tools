#!/usr/bin/env python3
"""Real Axum acceptance. Only recovery cases intercept requests.
Requires Python playwright, PyMuPDF, Pillow and installed Chromium/Firefox.
Usage: python scripts/elm-browser-acceptance.py --url http://127.0.0.1:3210
"""
import argparse
import io
import json
import pathlib
import time
import zipfile

import fitz
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:3210')
parser.add_argument('--browsers', default='chromium,firefox')
parser.add_argument('--output', default='/tmp/pdf-elm-acceptance')
parser.add_argument('--checks', default='theme,general,workspace_animation,recovery,intake_and_keyboard,fitting,mixed_and_saved,preview_recovery,lifecycle,responsive,startup')
args = parser.parse_args()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=True)
fixtures = root / 'fixtures'
fixtures.mkdir(exist_ok=True)


def pdf(name, labels, sizes=None):
    document = fitz.open()
    for index, label in enumerate(labels):
        width, height = sizes[index] if sizes else (216, 144)
        page = document.new_page(width=width, height=height)
        page.draw_rect(page.rect, color=None, fill=(1, 1, 1))
        page.insert_text((18, 50), label, fontsize=20)
        page.draw_rect(fitz.Rect(18, 70, 60, 110), color=None, fill=[(1,0,0),(0,1,0),(0,0,1)][index % 3])
    path = fixtures / name
    document.save(path)
    return path


three = pdf('three.pdf', ['PAGE-1', 'PAGE-2', 'PAGE-3'])
a_pdf = pdf('a.pdf', ['FIRST'])
b_pdf = pdf('b.pdf', ['SECOND'], [(288, 216)])
six = pdf('mixed.pdf', [f'ART-{n}' for n in range(1, 7)], [(216, 144), (288, 216), (252, 180), (216, 144), (288, 216), (252, 180)])
corrupt = fixtures / 'corrupt.pdf'
corrupt.write_bytes(b'%PDF-1.7\nnot a readable PDF')
image = Image.new('RGB', (900, 500), 'white')
draw = ImageDraw.Draw(image)
for box, color in [((0, 0, 299, 499), 'red'), ((300, 0, 599, 499), 'lime'), ((600, 0, 899, 499), 'blue')]:
    draw.rectangle(box, fill=color)
stripe = fixtures / 'stripes.png'
image.save(stripe)
small_jpeg = fixtures / 'small.jpg'
Image.new('RGB', (300, 600), 'yellow').save(small_jpeg, quality=95)
bleed_doc = fitz.open()
bleed_page = bleed_doc.new_page(width=288, height=216)
bleed_page.draw_rect(bleed_page.rect, color=None, fill=(0, 0, 1))
bleed_page.draw_rect(fitz.Rect(36, 36, 252, 180), color=None, fill=(1, 0, 0))
bleed_page.set_cropbox(fitz.Rect(36, 36, 252, 180))
bleed_page.set_trimbox(fitz.Rect(36, 36, 252, 180))
bleed = fixtures / 'bleed.pdf'
bleed_doc.save(bleed)


class Suite:
    def __init__(self, browser, name):
        self.browser = browser
        self.name = name
        self.context = browser.new_context(accept_downloads=True, viewport={'width': 1366, 'height': 900})
        self.context.add_init_script('''window.objectUrls={created:[],revoked:[]};
          const create=URL.createObjectURL.bind(URL), revoke=URL.revokeObjectURL.bind(URL);
          URL.createObjectURL=blob=>{const url=create(blob);objectUrls.created.push(url);return url};
          URL.revokeObjectURL=url=>{objectUrls.revoked.push(url);revoke(url)};''')
        self.page = self.context.new_page()
        self.layouts = []
        self.batch_sizes = []
        self.source_ids = []
        self.deleted_sources = []
        self.errors = []
        self.page.on('pageerror', lambda error: self.errors.append(str(error)))
        self.page.on('response', self.response)
        self.page.on('request', self.request)
        self.page.set_default_timeout(15000)
        self.page.goto(args.url)
        expect(self.button('Browse files')).to_be_visible()
        self.out = root / name
        self.out.mkdir(exist_ok=True)
        self.checks = []

    def response(self, response):
        if response.url.endswith('/gang-up/layout') and response.ok:
            self.layouts.append(response.json())
        if '/jobs/' in response.url and response.url.endswith('/download') and response.ok:
            if 'application/json' in response.headers.get('content-type', ''):
                self.source_ids.append(response.json()['sourceId'])

    def request(self, request):
        if request.url.endswith('/previews') and request.method == 'POST':
            self.batch_sizes.append(len(request.post_data_json['pageNumbers']))
        if '/gang-up/sources/' in request.url and request.method == 'DELETE':
            self.deleted_sources.append(request.url.rsplit('/', 1)[-1])

    def button(self, name):
        return self.page.get_by_role('button', name=name, exact=True)

    def select(self, files, append=False):
        if isinstance(files, pathlib.Path):
            files = [files]
        if self.page.get_by_role('button', name='Browse files', exact=True).count():
            trigger = self.button('Browse files')
        elif append:
            trigger = self.button('Add artwork' if self.button('Add artwork').count() else 'Add files')
        else:
            trigger = self.button('Replace artwork' if self.button('Replace artwork').count() else 'Replace files')
        with self.page.expect_file_chooser() as chooser:
            trigger.click()
        chooser.value.set_files([str(path) for path in files])

    def idle(self):
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        expect(self.page.get_by_role('button', name='Cancel', exact=True)).to_have_count(0, timeout=60000)
        expect(self.page.get_by_role('button', name='Cancel inspection', exact=True)).to_have_count(0, timeout=60000)
        expect(self.page.locator('[data-layout-state=pending]')).to_have_count(0, timeout=60000)
        expect(self.page.locator('.preview-cache-status').filter(has_text='Updating preview')).to_have_count(0, timeout=60000)

    def download(self, name, output):
        self.idle()
        with self.page.expect_download(timeout=60000) as download:
            self.button(name).click()
        path = self.out / output
        download.value.save_as(str(path))
        assert path.stat().st_size > 10
        self.idle()
        return path

    def fresh(self):
        self.page.goto(args.url)
        expect(self.button('Browse files')).to_be_visible()

    def switch(self, name):
        self.idle()
        self.button(name).click()

    def theme(self):
        for saved, expected in [(None, 'dark'), ('invalid', 'dark'), ('light', 'light'), ('dark', 'dark'), ('blocked', 'dark')]:
            context = self.browser.new_context(color_scheme='light', viewport={'width': 390, 'height': 700})
            if saved == 'blocked':
                context.add_init_script("Object.defineProperty(window, 'localStorage', {get() {throw new Error('Storage unavailable')}})")
            elif saved is not None:
                context.add_init_script(f"localStorage.setItem('pdf-tools-theme', {json.dumps(saved)})")
            page = context.new_page()
            page.goto(args.url)
            toggle = page.get_by_role('switch', name='Dark mode')
            expect(toggle).to_be_visible()
            expect(page.locator('html')).to_have_attribute('data-theme', expected)
            expect(toggle).to_have_attribute('aria-checked', str(expected == 'dark').lower())
            page.emulate_media(color_scheme='dark')
            page.emulate_media(color_scheme='light')
            expect(page.locator('html')).to_have_attribute('data-theme', expected)
            toggle.focus()
            expect(toggle).to_be_focused()
            toggle.press('Space')
            opposite = 'light' if expected == 'dark' else 'dark'
            expect(page.locator('html')).to_have_attribute('data-theme', opposite)
            expect(toggle).to_have_attribute('aria-checked', str(opposite == 'dark').lower())
            toggle.press('Enter')
            expect(page.locator('html')).to_have_attribute('data-theme', expected)
            context.close()

        context = self.browser.new_context(color_scheme='light')
        page = context.new_page()
        page.goto(args.url)
        toggle = page.get_by_role('switch', name='Dark mode')
        for theme in ['light', 'dark']:
            toggle.click()
            page.reload()
            expect(page.locator('html')).to_have_attribute('data-theme', theme)
            expect(toggle).to_have_attribute('aria-checked', str(theme == 'dark').lower())
        context.close()
        self.checks.append('theme: dark default on light OS, saved/invalid/unavailable storage, system changes, keyboard activation, both themes persist')

    def range(self, draft):
        self.button('Page range').click()
        self.page.locator('#range-input').fill(draft)
        self.button('Apply range').click()
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)

    def impose(self, files):
        self.select(files)
        self.idle()
        if self.page.locator('#finished-width').count() == 0:
            self.switch('Impose artwork')
        self.page.locator('#finished-width').wait_for(timeout=60000)
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.idle()
        expect(self.page.locator('.sheet-svg')).to_be_visible()

    def continue_to(self, step):
        while self.page.locator('.setup-stepper button[aria-current=step]').inner_text().strip() != step:
            active = self.page.locator('.setup-stepper button[aria-current=step]')
            before = active.inner_text().strip()
            self.button('Continue').click()
            expect(active).not_to_have_text(before)
        self.idle()

    def step(self, name):
        self.page.locator('.setup-stepper').get_by_role('button', name=name, exact=True).click()

    def artwork(self):
        menu = self.page.locator('.elm-artwork-menu')
        if menu.get_attribute('open') is None:
            menu.locator('summary').click()
        return menu

    def close_artwork(self):
        menu = self.page.locator('.elm-artwork-menu')
        if menu.get_attribute('open') is not None:
            menu.locator('summary').click()

    def assert_pdf(self, path, labels, sizes=None):
        with fitz.open(path) as document:
            assert len(document) == len(labels), (path, len(document), labels)
            for i, label in enumerate(labels):
                assert label in document[i].get_text(), (path, i, document[i].get_text())
                if sizes:
                    assert abs(document[i].rect.width - sizes[i][0]) < .1
                    assert abs(document[i].rect.height - sizes[i][1]) < .1

    def general(self):
        self.select(three)
        self.idle()
        self.button('Page range').click()
        self.page.locator('#range-input').fill('99')
        expect(self.button('Apply range')).to_be_disabled()
        self.page.locator('#range-input').fill('3,1')
        self.button('Apply range').press('Enter')
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)
        # Rust maintains source order even when the user enters 3,1.
        for target in ['PNG', 'JPEG']:
            self.button(target).click()
            path = self.download('Download images', f'{target.lower()}.zip')
            with zipfile.ZipFile(path) as archive:
                images = [Image.open(io.BytesIO(archive.read(name))) for name in archive.namelist()]
                assert len(images) == 2
                assert all(im.format == target for im in images)
                assert all(im.size == (432, 288) for im in images), [im.size for im in images]
                for im,channel in zip(images,[0,2]):
                    pixel=im.convert('RGB').getpixel((50,160))
                    assert pixel[channel]>220 and sum(pixel)<320,(target,channel,pixel)
        self.button('Standard').click()
        path = self.download('Download images', 'standard.zip')
        with zipfile.ZipFile(path) as archive:
            im = Image.open(io.BytesIO(archive.read(archive.namelist()[0])))
            assert im.size == (900, 600), im.size
        self.button('High').click()
        path = self.download('Download images', 'high.zip')
        with zipfile.ZipFile(path) as archive:
            im = Image.open(io.BytesIO(archive.read(archive.namelist()[0])))
            assert im.size == (1800, 1200)
        self.switch('Extract pages')
        self.range('1,3')
        for mode in ['Individual', 'Combined', 'Chunks']:
            self.button(mode).click()
            if mode == 'Chunks':
                self.page.locator('#extract-chunk-size').fill('0')
                expect(self.button('Download ZIP')).to_be_disabled()
                self.page.locator('#extract-chunk-size').fill('1')
            path = self.download('Download PDF' if mode == 'Combined' else 'Download ZIP', f'extract-{mode}.pdf' if mode == 'Combined' else f'extract-{mode}.zip')
            if mode == 'Combined':
                self.assert_pdf(path, ['PAGE-1', 'PAGE-3'])
            else:
                with zipfile.ZipFile(path) as archive:
                    assert len(archive.namelist()) == 2
                    for name, label in zip(archive.namelist(), ['PAGE-1', 'PAGE-3']):
                        with fitz.open(stream=archive.read(name), filetype='pdf') as document:
                            assert len(document) == 1 and label in document[0].get_text()
        self.button('Chunks').click()
        self.button('All pages').click()
        self.page.locator('#extract-chunk-size').fill('2')
        path = self.download('Download ZIP', 'chunks-two.zip')
        with zipfile.ZipFile(path) as archive:
            documents = [fitz.open(stream=archive.read(n), filetype='pdf') for n in archive.namelist()]
            assert [len(d) for d in documents] == [2, 1]
            assert ['PAGE-1' in documents[0][0].get_text(), 'PAGE-2' in documents[0][1].get_text(), 'PAGE-3' in documents[1][0].get_text()] == [True, True, True]
        self.select([a_pdf, b_pdf])
        self.idle()
        self.switch('Combine PDFs')
        self.page.get_by_role('button', name='Move b.pdf up', exact=True).press('Enter')
        path = self.download('Download PDF', 'merged.pdf')
        self.assert_pdf(path, ['SECOND', 'FIRST'], [(288,216), (216,144)])
        self.page.get_by_role('button', name='Remove a.pdf', exact=True).click()
        expect(self.page.locator('.file-row')).to_have_count(1)
        self.select(a_pdf, append=True)
        self.idle()
        expect(self.page.locator('.file-row')).to_have_count(2)
        self.select([stripe, small_jpeg])
        self.idle()
        expect(self.button('Images to PDF')).to_be_visible()
        self.page.get_by_role('button', name='Move small.jpg up', exact=True).click()
        path = self.download('Create PDF', 'images.pdf')
        with fitz.open(path) as document:
            assert len(document) == 2
            assert tuple(document[0].rect)[2:] == (72, 144)
            assert tuple(document[1].rect)[2:] == (216, 120)
            color = document[0].get_pixmap().pixel(30,30)
            assert color[0] > 220 and color[1] > 220 and color[2] < 30, color
        toggle = self.page.get_by_role('switch')
        if toggle.get_attribute('aria-checked') == 'true':
            toggle.click()
        expect(self.page.locator('html')).to_have_attribute('data-theme','light')
        toggle.click()
        expect(self.page.locator('html')).to_have_attribute('data-theme','dark')
        self.page.reload()
        expect(self.page.locator('html')).to_have_attribute('data-theme','dark')
        self.checks.append('general: PNG/JPEG + all resolutions, extraction modes/chunks/order, PDF merge/order/dimensions, natural image pages/order, theme persistence')

    def recovery(self):
        self.fresh()
        self.select(three)
        self.idle()
        self.button('JPEG').click()
        self.select(corrupt)
        expect(self.page.get_by_role('alert')).to_contain_text('')
        expect(self.page.locator('.app-file-context strong')).to_have_text('three.pdf')
        expect(self.button('JPEG')).to_have_attribute('aria-pressed','true')
        self.select(a_pdf)
        self.idle()
        expect(self.page.locator('.app-file-context strong')).to_have_text('a.pdf')
        pending = []
        self.page.route('**/pdf/inspect', lambda route: pending.append((route, route.fetch())))
        self.select(three)
        self.button('Cancel inspection').wait_for()
        self.button('Cancel inspection').click()
        assert pending
        for route, response in pending:
            try: route.fulfill(response=response)
            except Exception: pass  # A native Elm Http.cancel may have already aborted it.
        self.page.unroute('**/pdf/inspect')
        self.page.wait_for_timeout(200)
        expect(self.page.locator('.app-file-context strong')).to_have_text('a.pdf')
        self.button('Retry').click() if self.button('Retry').count() else self.select(three)
        self.idle()
        self.page.route('**/jobs', lambda route: route.fulfill(status=503, body='Controlled export failure'))
        self.button('Download images').click()
        expect(self.page.get_by_role('alert')).to_contain_text('Controlled export failure')
        self.page.unroute('**/jobs')
        with self.page.expect_download(timeout=60000) as output:
            self.button('Retry').click()
        output.value.save_as(str(self.out/'retried.zip'))
        assert zipfile.is_zipfile(self.out/'retried.zip')
        self.idle()
        pending = []
        self.page.route('**/jobs', lambda route: pending.append((route,route.fetch())))
        self.button('Download images').click()
        self.button('Cancel').click()
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/jobs')
        self.page.wait_for_timeout(300)
        expect(self.page.locator('.app-file-context strong')).to_have_text('three.pdf')
        assert self.page.get_by_role('status').filter(has_text='Cancelled').count()
        self.checks.append('recovery: corrupt replacement retains files/settings, inspection cancellation/stale success, export failure/retry, cancelled upload late job response')

    def intake_and_keyboard(self):
        self.fresh()
        def drop(path):
            transfer=self.page.evaluate_handle('''({bytes,name,type})=>{const dt=new DataTransfer();dt.items.add(new File([new Uint8Array(bytes)],name,{type}));return dt}''',{'bytes':list(path.read_bytes()),'name':path.name,'type':'application/pdf'})
            self.page.locator('.elm-shell').dispatch_event('drop',{'dataTransfer':transfer})
        drop(a_pdf)
        self.idle()
        drop(b_pdf)
        self.idle()
        self.switch('Combine PDFs')
        moving=self.page.locator('.file-row').filter(has_text='b.pdf')
        moving.focus()
        moving.press('Alt+ArrowUp')
        expect(moving).to_be_focused()
        expect(self.page.locator('.file-row').first).to_contain_text('b.pdf')
        moving.press('Alt+ArrowDown')
        expect(moving).to_be_focused()
        moving.press('Alt+ArrowUp')
        path=self.download('Download PDF','keyboard-merge.pdf')
        self.assert_pdf(path,['SECOND','FIRST'])
        # Pointer reordering uses the same stable file identity.
        source=self.page.locator('.file-row').filter(has_text='a.pdf')
        target=self.page.locator('.file-row').filter(has_text='b.pdf')
        source.drag_to(target)
        expect(self.page.locator('.file-row').first).to_contain_text('a.pdf')
        self.select(three)
        self.idle()
        self.switch('Extract pages')
        opener=self.button('Page range')
        opener.click()
        self.page.locator('#range-input').press('Escape')
        expect(opener).to_be_focused()
        # Multiple input formats use the canonical mixed-source path.
        self.select([a_pdf,stripe,small_jpeg])
        self.idle()
        expect(self.page.locator('#finished-width')).to_have_value('')
        expect(self.page.get_by_label('Finished orientation',exact=True)).to_be_disabled()
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.page.get_by_label('Finished orientation',exact=True).select_option('portrait')
        expect(self.page.locator('#finished-width')).to_have_value('2')
        self.page.get_by_label('Finished orientation',exact=True).select_option('landscape')
        self.idle()
        assert len(self.layouts[-1]['pagePlans'])==3
        self.page.get_by_text('Artwork files',exact=True).click()
        self.page.get_by_role('button',name='Move small.jpg up',exact=True).click()
        self.idle()
        self.page.get_by_role('button',name='Remove stripes.png',exact=True).click()
        self.idle()
        assert len(self.layouts[-1]['pagePlans'])==2
        expect(self.page.locator('#finished-width')).to_have_value('3')
        self.continue_to('Bleed')
        path=self.download('Download imposed PDF','mixed-inputs.pdf')
        with fitz.open(path) as doc:
            assert len(doc)==self.layouts[-1]['sheetsRequired']
            assert 'FIRST' in ''.join(p.get_text() for p in doc)
            pix=doc[0].get_pixmap()
            cut=self.layouts[-1]['placements'][1]
            color=pix.pixel(round((cut['finishedX']+cut['finishedWidth']/2)*72),round((cut['finishedY']+cut['finishedHeight']/2)*72))
            assert color[0]>220 and color[1]>220 and color[2]<30,color
        self.checks.append('intake/keyboard: native file drops and append, keyboard/pointer ordering + stable focus, dialog Escape focus, mixed PDF/PNG/JPEG preparation/reorder/remove/output, explicit dimensions and finished orientation')

    def fitting(self):
        self.fresh()
        self.impose(stripe)
        expect(self.button('Continue')).to_be_enabled()
        self.page.locator('#finished-width').fill('')
        expect(self.button('Continue')).to_be_disabled()
        width = self.page.locator('#finished-width')
        width.press('Control+A')
        width.press('Backspace')
        width.press_sequentially('8.5', delay=40)
        expect(width).to_have_value('8.5')
        self.page.locator('#finished-height').fill('11')
        self.continue_to('Arrangement')
        self.page.get_by_text('Advanced sheet settings', exact=True).click()
        self.page.locator('#gang-setup-panel').get_by_label('Impression orientation',exact=True).select_option('upright')
        self.idle()
        self.continue_to('Bleed')
        for fit in ['Fit', 'Fill', 'Stretch']:
            menu = self.artwork()
            menu.get_by_role('button',name=fit,exact=True).click()
            self.idle()
            self.close_artwork()
            path = self.download('Download imposed PDF', f'imposed-{fit}.pdf')
            layout = self.layouts[-1]
            with fitz.open(path) as doc:
                assert len(doc) == layout['sheetsRequired']
                assert abs(doc[0].rect.width - 864) < .1 and abs(doc[0].rect.height - 1296) < .1
                pix = doc[0].get_pixmap()
                cut = layout['placements'][0]
                x = cut['finishedX']*72
                y = cut['finishedY']*72
                w = cut['finishedWidth']*72
                h = cut['finishedHeight']*72
                sample = lambda xf,yf: pix.pixel(round(x+w*xf),round(y+h*yf))
                if fit == 'Fit':
                    assert min(sample(.5,.05)) > 240, sample(.5,.05)
                    assert sample(.5,.5)[1] > 240
                if fit == 'Stretch':
                    for yf in [.05,.5,.95]:
                        for xf,channel in [(.1,0),(.5,1),(.9,2)]:
                            color=sample(xf,yf)
                            assert color[channel] > 240 and sum(color) < 300, (fit,xf,yf,color)
                    menu=self.artwork()
                    assert menu.get_by_text('Crop position',exact=True).count() == 0
                    self.close_artwork()
                # SVG cut dimensions come from the same authoritative Rust plan.
                svg=self.page.locator('.sheet-svg .piece-cut').first
                assert abs(float(svg.get_attribute('width')) - cut['finishedWidth']) < .001
                assert abs(float(svg.get_attribute('height')) - cut['finishedHeight']) < .001
        menu=self.artwork()
        menu.get_by_role('button',name='Fill',exact=True).click()
        self.idle()
        for position,channel in [('0',0),('1',2)]:
            menu.get_by_label('Horizontal position',exact=True).fill(position)
            self.idle()
            self.close_artwork()
            path=self.download('Download imposed PDF',f'crop-{position}.pdf')
            layout=self.layouts[-1]
            with fitz.open(path) as doc:
                cut=layout['placements'][0]
                color=doc[0].get_pixmap().pixel(round((cut['finishedX']+cut['finishedWidth']/2)*72),round((cut['finishedY']+cut['finishedHeight']/2)*72))
                assert color[channel] > 240, (position,color)
            menu=self.artwork()
        menu.get_by_role('button',name='Reset crop position',exact=True).click()
        self.idle()
        editor=menu.locator('.elm-crop-editor')
        editor.scroll_into_view_if_needed()
        box=editor.bounding_box()
        self.page.mouse.move(box['x']+box['width']/2,box['y']+box['height']/2)
        self.page.mouse.down()
        self.page.mouse.move(box['x']+box['width']*.7,box['y']+box['height']/2,steps=5)
        self.page.mouse.up()
        self.idle()
        assert float(menu.get_by_label('Horizontal position',exact=True).input_value()) < .5
        self.close_artwork()
        self.button('Scale to add bleed').click()
        self.page.get_by_label('Extend per side (in)',exact=True).fill('0.125')
        self.idle()
        path=self.download('Download imposed PDF','created-bleed.pdf')
        with fitz.open(path) as doc: assert len(doc)==self.layouts[-1]['sheetsRequired']
        self.checks.append('imposition fitting: decimal typing/validation, Fit/Fill/Stretch exported dimensions and colored pixels, crop endpoints/drag/reset, created bleed, SVG/export cut geometry')

    def mixed_and_saved(self):
        self.fresh()
        self.impose(six)
        assert all(size <= 4 for size in self.batch_sizes) and 4 in self.batch_sizes
        assert len(self.layouts[-1]['pagePlans']) == 6
        self.button('Repeat pages').click()
        self.continue_to('Quantity & sheet')
        self.button('Edit copy quantities').click()
        self.page.locator('#bulk-copy-quantity').fill('-1')
        expect(self.button('Apply to all')).to_be_disabled()
        self.page.locator('#bulk-copy-quantity').fill('0')
        self.button('Apply to all').press('Enter')
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)
        expect(self.button('Continue')).to_be_disabled()
        self.button('Edit copy quantities').click()
        self.page.locator('#bulk-copy-quantity').fill('2')
        self.button('Apply to all').click()
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2]*6
        self.button('Edit copy quantities').click()
        self.page.get_by_label('Page 2 copies',exact=True).fill('0')
        self.button('Done').click()
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        self.page.get_by_label('Printing',exact=True).select_option('double')
        self.idle()
        assert len(self.layouts[-1]['impressionQuantities']) == 3
        self.page.get_by_label('Printing',exact=True).select_option('single')
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        menu=self.artwork()
        menu.get_by_label('Selected artwork',exact=True).select_option('3')
        menu.get_by_label('Adjust only selected artwork',exact=True).check()
        menu.get_by_label('Artwork finished width (in)',exact=True).fill('2')
        menu.get_by_label('Artwork finished height (in)',exact=True).fill('1.5')
        menu.get_by_role('button',name='Stretch',exact=True).click()
        self.idle()
        assert self.layouts[-1]['pagePlans'][2]['finishedCutSize']=={'width':2.0,'height':1.5}
        assert self.layouts[-1]['pagePlans'][0]['finishedCutSize']=={'width':3.0,'height':2.0}
        self.close_artwork()
        self.continue_to('Bleed')
        path=self.download('Download imposed PDF','mixed-repeat.pdf')
        layout=self.layouts[-1]
        with fitz.open(path) as doc:
            assert len(doc)==layout['sheetsRequired']
            content=''.join(p.get_text() for p in doc)
            assert 'ART-1' in content and 'ART-3' in content and 'ART-2' not in content, content
        self.step('Size')
        self.page.locator('#gang-setup-panel').get_by_text('Presets',exact=True).click()
        name=f'Elm {self.name} acceptance {time.time_ns()}'
        self.page.get_by_label('Setup name',exact=True).fill(name)
        self.button('Save preset').click()
        expect(self.page.get_by_label('Apply preset').locator('option').filter(has_text=name)).to_have_count(1)
        preset_id=self.page.get_by_label('Apply preset').locator('option').filter(has_text=name).get_attribute('value')
        self.button('Save recent job').click()
        self.page.get_by_text('Recent jobs',exact=True).click()
        expect(self.page.locator('.elm-saved li').filter(has_text=name)).to_have_count(2)
        self.page.locator('#finished-width').fill('bad')
        expect(self.button('Continue')).to_be_disabled()
        self.page.get_by_label('Apply preset').select_option(preset_id)
        expect(self.page.locator('#finished-width')).to_have_value('3')
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        expect(self.page.locator('.app-file-context strong')).to_have_text('mixed.pdf')
        self.page.get_by_label('Setup name',exact=True).fill(name+' renamed')
        self.button('Update preset').click()
        expect(self.page.get_by_label('Apply preset').locator('option').filter(has_text=name+' renamed')).to_have_count(1)
        self.page.get_by_label('Setup name',exact=True).fill(name+' renamed again')
        self.button('Rename').click()
        expect(self.page.get_by_label('Apply preset').locator('option').filter(has_text=name+' renamed again')).to_have_count(1)
        self.page.get_by_text('Export history',exact=True).click()
        history=self.page.locator('.elm-saved details').filter(has=self.page.get_by_text('Export history',exact=True))
        expect(history.get_by_role('link',name='Download',exact=True).first).to_be_visible()
        with self.page.expect_download() as download: history.get_by_role('link',name='Download',exact=True).first.click()
        download.value.save_as(str(self.out/'history.pdf'))
        assert (self.out/'history.pdf').read_bytes()==path.read_bytes()
        with fitz.open(self.out/'history.pdf') as doc: assert len(doc)==layout['sheetsRequired']
        self.page.locator('#finished-width').fill('bad')
        history.get_by_role('button',name='Restore setup',exact=True).first.click()
        expect(self.page.locator('#finished-width')).to_have_value('3')
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        history_count=history.locator('li').count()
        history.get_by_role('button',name='Delete',exact=True).first.click()
        expect(history.locator('li')).to_have_count(history_count-1)
        recent=self.page.locator('.elm-saved details').filter(has=self.page.get_by_text('Recent jobs',exact=True))
        row=recent.locator('li').filter(has_text=name)
        row.get_by_role('button',name='Restore setup',exact=True).click()
        self.idle()
        menu=self.artwork()
        menu.get_by_label('Selected artwork',exact=True).select_option('3')
        menu.get_by_label('Adjust only selected artwork',exact=True).check()
        menu.get_by_role('button',name='Use shared settings for this artwork',exact=True).click()
        self.idle()
        self.close_artwork()
        self.step('Quantity & sheet')
        self.page.get_by_label('Printing',exact=True).select_option('double')
        self.idle()
        self.step('Arrangement')
        self.page.get_by_text('Advanced sheet settings',exact=True).click()
        self.page.get_by_label('Duplex flip edge',exact=True).select_option('shortEdge')
        self.page.get_by_label('Rotate back side 180°',exact=True).check()
        self.idle()
        self.step('Bleed')
        path=self.download('Download imposed PDF','duplex.pdf')
        layout=self.layouts[-1]
        with fitz.open(path) as doc:
            assert len(doc)==2*layout['sheetsRequired']
            assert 'ART-1' in doc[0].get_text() and 'ART-2' in doc[1].get_text()
        self.step('Arrangement')
        self.button('Custom grid').click()
        self.page.get_by_label('Rows',exact=True).fill('2')
        self.page.get_by_label('Columns',exact=True).fill('2')
        self.idle()
        assert self.layouts[-1]['rows']==2 and self.layouts[-1]['columns']==2
        self.page.get_by_text('Advanced sheet settings',exact=True).click()
        self.page.get_by_label('Center grid automatically',exact=True).uncheck()
        remaining=self.layouts[-1]['margins']['top']+self.layouts[-1]['margins']['bottom']
        self.page.get_by_label('Top margin (in)',exact=True).fill('0.5')
        self.idle()
        expect(self.page.get_by_role('alert')).to_be_visible()
        self.page.get_by_label('Bottom margin (in)',exact=True).fill(str(remaining-.5))
        self.idle()
        assert abs(self.layouts[-1]['margins']['top']-.5)<.001
        self.step('Size')
        self.page.locator('#gang-setup-panel').get_by_text('Presets',exact=True).click()
        self.page.get_by_text('Manage presets',exact=True).click()
        self.page.locator('.elm-saved li').filter(has_text=name+' renamed again').get_by_role('button',name='Delete',exact=True).click()
        expect(self.page.get_by_label('Apply preset').locator('option').filter(has_text=name)).to_have_count(0)
        self.page.get_by_text('Recent jobs',exact=True).click()
        self.page.locator('.elm-saved li').filter(has_text=name).get_by_role('button',name='Delete',exact=True).click()
        expect(self.page.locator('.elm-saved li').filter(has_text=name)).to_have_count(0)
        self.checks.append('mixed/saved: four-page batch bound, distinct geometry/per-artwork overrides, zero/bulk/individual copies, simplex/duplex drafts + exported fronts/backs, manual grid/margins, preset CRUD/repair/retention, recent restore/delete, history restore/delete and stored download')

    def preview_recovery(self):
        self.fresh()
        self.impose(bleed)
        self.continue_to('Bleed')
        old_url=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        def raster(url):
            data=self.page.evaluate('url=>fetch(url).then(r=>r.arrayBuffer()).then(b=>Array.from(new Uint8Array(b)))',url)
            return Image.open(io.BytesIO(bytes(data))).convert('RGB')
        assert raster(old_url).getpixel((0,0))[0]>220
        pending=[]
        self.page.route('**/gang-up/sources/*/previews',lambda route: pending.append((route,route.fetch())))
        self.button('Enter bleed manually').click()
        self.button('Clear manual amount').wait_for()
        self.page.wait_for_timeout(350)
        assert pending
        current=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        assert current==old_url, 'Displayed preview changed while its replacement was pending'
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/gang-up/sources/*/previews')
        self.idle()
        self.button('Clear manual amount').click()
        self.idle()
        attempts=[]
        def fail_preview(route):
            attempts.append(route.request.post_data_json)
            route.fulfill(status=503,body='Controlled preview failure')
        self.page.route('**/gang-up/sources/*/previews',fail_preview)
        self.button('Enter bleed manually').click()  # Change identity to an uncached amount below.
        self.page.get_by_label('PDF bleed per side (in)',exact=True).fill('0.2')
        expect(self.button('Retry preview')).to_be_visible(timeout=30000)
        assert 1 <= len(attempts) <= 4, attempts
        current=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        assert current==old_url
        self.page.unroute('**/gang-up/sources/*/previews')
        self.button('Retry preview').click()
        self.idle()
        new_url=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        assert new_url!=old_url and raster(new_url).getpixel((0,0))[2]>220,(old_url,new_url,raster(new_url).getpixel((0,0)),self.layouts[-1]['sourceBleedOverride'])
        path=self.download('Download imposed PDF','manual-bleed.pdf')
        with fitz.open(path) as doc: assert len(doc)==self.layouts[-1]['sheetsRequired']
        old_source=self.source_ids[-1]
        self.select(corrupt)
        expect(self.page.get_by_role('alert')).to_be_visible()
        expect(self.page.locator('.app-file-context strong')).to_have_text('bleed.pdf')
        self.select(three)
        self.idle()
        expect(self.page.locator('.app-file-context strong')).to_have_text('three.pdf')
        assert old_source in self.deleted_sources, (old_source,self.deleted_sources)
        assert old_url in self.page.evaluate('objectUrls.revoked')
        assert new_url in self.page.evaluate('objectUrls.revoked')
        with self.page.expect_request('**/gang-up/sources/*/lease') as lease:
            self.page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
        assert lease.value.method=='PUT'
        # Cancel a prepared-source POST after the real backend accepted it. Its
        # late job ID must clean up instead of replacing the previous artwork.
        pending=[]
        self.page.route('**/gang-up/sources',lambda route: pending.append((route,route.fetch())))
        self.select(six)
        self.button('Cancel').wait_for()
        self.button('Cancel').click()
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/gang-up/sources')
        self.page.wait_for_timeout(500)
        expect(self.page.locator('.app-file-context strong')).to_have_text('three.pdf')
        self.checks.append('preview/replacement: retained raster during delayed replacement, bounded automatic retries + explicit recovery, manual-bleed cache identity, corrupt replacement, source deletion, cancelled preparation late response')

    def lifecycle(self):
        self.fresh()
        self.impose(three)
        old_url=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        source=self.source_ids[-1]
        self.button('Clear').click()
        self.button('Keep working').click()
        expect(self.page.locator('.app-file-context strong')).to_have_text('three.pdf')
        pending=[]
        self.page.route('**/gang-up/layout',lambda route:pending.append((route,route.fetch())))
        self.page.locator('#finished-width').fill('4.25')
        self.page.wait_for_timeout(350)
        assert pending
        self.button('Clear').click()
        self.button('Clear files').click()
        expect(self.button('Browse files')).to_be_visible()
        for route,response in pending:
            try: route.fulfill(response=response)
            except Exception: pass  # Cleared layout tracker may already be aborted.
        self.page.unroute('**/gang-up/layout')
        self.page.wait_for_timeout(200)
        expect(self.button('Browse files')).to_be_visible()
        assert source in self.deleted_sources
        assert old_url in self.page.evaluate('objectUrls.revoked')
        self.select(a_pdf)
        self.idle()
        self.switch('Impose artwork')
        self.page.locator('#finished-width').wait_for(timeout=60000)
        expect(self.page.locator('#finished-width')).to_have_value('')
        expect(self.button('Continue')).to_be_disabled()
        self.checks.append('lifecycle: clear confirmation/cancel, late layout after clear rejected, source deletion and URL revocation, new upload requires explicit finished dimensions')

    def workspace_animation(self):
        self.fresh()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.select(stripe)
        self.idle()
        samples = self.button('Impose artwork').evaluate('''button => new Promise(resolve => {
          const bounds = () => {
            const r = document.querySelector('.ready-card').getBoundingClientRect();
            return {x:r.x, y:r.y, width:r.width, height:r.height};
          };
          const frames = [bounds()], start = performance.now();
          button.click();
          const sample = now => {
            frames.push(bounds());
            if (now - start < 650) requestAnimationFrame(sample);
            else resolve(frames);
          };
          requestAnimationFrame(sample);
        })''')
        first, last = samples[0], samples[-1]
        assert first['width'] < last['width'] - 100, samples
        assert first['height'] < last['height'] - 100, samples
        assert any(first['width'] + 10 < frame['width'] < last['width'] - 10 for frame in samples), samples
        assert any(first['height'] + 10 < frame['height'] < last['height'] - 10 for frame in samples), samples
        assert all(frame['width'] <= last['width'] + 1 for frame in samples), samples
        assert all(after['width'] >= before['width'] - 1 for before, after in zip(samples, samples[1:])), samples
        assert abs(last['x']) < 1 and abs(last['width'] - 1366) < 1, last
        assert abs(last['y'] + last['height'] - 900) < 1, last
        self.idle()
        self.page.screenshot(path=str(self.out/'impose-expanded.png'))
        self.switch('Images to PDF')
        self.idle()
        self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
        assert self.page.locator('.ready-card').bounding_box()['width'] < 1366 - 100
        self.page.emulate_media(reduced_motion='reduce')
        self.switch('Impose artwork')
        self.idle()
        assert self.page.locator('.elm-shell').get_attribute('data-workspace-animating') is None
        frame = self.page.locator('.ready-card.imposing').bounding_box()
        assert abs(frame['x']) < 1 and abs(frame['width'] - 1366) < 1, frame
        self.page.emulate_media(reduced_motion='no-preference')
        self.checks.append('workspace animation: visible monotonic expansion without overshoot, full viewport bounds, return to centered tool, reduced-motion bypass')

    def responsive(self):
        self.fresh()
        self.impose(stripe)
        self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
        viewports=[(1366,900),(1366,560),(1101,768),(1100,768),(1024,768),(881,700),(880,700),(800,900),(540,700),(539,700),(390,700),(320,568)]
        # CI's DejaVu fallback is wider than fonts installed on some desktops.
        # Exercise it at every viewport for step labels and header wrapping.
        cases=[(width,height,font) for font in ['', 'DejaVu Sans, sans-serif'] for width,height in viewports]
        for width,height,font in cases:
            self.page.evaluate('(font) => document.documentElement.style.fontFamily = font',font)
            suffix='-dejavu' if font else ''
            self.page.set_viewport_size({'width':width,'height':height})
            self.page.wait_for_timeout(80)
            frame = self.page.locator('.ready-card.imposing').bounding_box()
            header = self.page.locator('.app-header').bounding_box()
            assert abs(frame['x']) < 1 and abs(frame['width'] - width) < 1, (width, height, frame)
            assert abs(frame['y'] + frame['height'] - height) < 1, (width, height, frame)
            assert abs(header['x'] - frame['x']) < 1 and abs(header['width'] - frame['width']) < 1, (width, height, header, frame)
            toggle = self.page.get_by_role('switch', name='Dark mode')
            bounds = toggle.bounding_box()
            assert abs(bounds['width'] - 44) < 0.5 and abs(bounds['height'] - 44) < 0.5, (width, height, bounds)
            assert toggle.evaluate('e => { const r = e.getBoundingClientRect(); return e.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)); }'), (width, height, 'Theme switch is clipped')
            if width<=1100:
                self.page.get_by_role('tab',name='Setup',exact=True).click()
            action=self.button('Continue')
            action.scroll_into_view_if_needed()
            box=action.bounding_box()
            assert box and box['x']>=-1 and box['y']>=-1 and box['x']+box['width']<=width+1 and box['y']+box['height']<=height+1,(width,height,box)
            assert self.page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'),(width,height)
            assert self.page.evaluate('''() => {
              const button=[...document.querySelectorAll('button')].find(b=>b.textContent==='Continue');
              const r=button.getBoundingClientRect();const at=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return at===button||button.contains(at);
            }'''), (width,height,'Continue is clipped')
            # Existing labels remain readable instead of breaking inside words.
            for selector in ['.setup-stepper button','.app-header-actions']:
                assert self.page.locator(selector).evaluate_all('(xs)=>xs.every(e=>e.scrollWidth<=e.clientWidth+2)'),(width,height,selector)
            fields=self.page.locator('.gang-setup-fields')
            assert fields.bounding_box()['height']>60,(width,height,'Setup scroller collapsed')
            dimension=self.page.locator('#finished-width')
            dimension.scroll_into_view_if_needed()
            bounds=dimension.bounding_box()
            assert bounds['y']>=0 and bounds['y']+bounds['height']<=height,(width,height,bounds)
            self.page.screenshot(path=str(self.out/f'setup-{width}x{height}{suffix}.png'))
            menu=self.artwork()
            menu.get_by_role('button',name='Fill',exact=True).click()
            self.idle()
            editor=menu.locator('.elm-crop-editor')
            editor.scroll_into_view_if_needed()
            panel=menu.locator('fieldset').bounding_box()
            assert panel['x']>=-1 and panel['x']+panel['width']<=width+1 and panel['y']+panel['height']<=height+1,(width,height,panel)
            self.page.screenshot(path=str(self.out/f'artwork-{width}x{height}{suffix}.png'))
            menu.get_by_role('button',name='Fit',exact=True).click()
            self.idle()
            self.close_artwork()
            if width<=1100:
                self.page.get_by_role('tab',name='Preview',exact=True).click()
            sheet=self.page.locator('.sheet-svg')
            expect(sheet).to_be_visible()
            box=sheet.bounding_box()
            assert box['width']>80 and box['height']>80,(width,height,box)
            self.page.screenshot(path=str(self.out/f'impose-{width}x{height}{suffix}.png'))
        self.page.get_by_role('switch', name='Dark mode').click()
        expect(self.page.locator('html')).to_have_attribute('data-theme', 'light')
        for width, height in [(1366, 900), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            self.page.wait_for_timeout(80)
            if width <= 1100:
                self.page.get_by_role('tab', name='Preview', exact=True).click()
            expect(self.page.locator('.sheet-svg')).to_be_visible()
            self.page.screenshot(path=str(self.out/f'impose-light-{width}x{height}.png'))
        self.page.get_by_role('switch', name='Dark mode').click()
        self.page.set_viewport_size({'width':390,'height':700})
        self.switch('Images to PDF')
        expect(self.button('Create PDF')).to_be_visible()
        self.button('Create PDF').scroll_into_view_if_needed()
        assert self.page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1')
        self.page.screenshot(path=str(self.out/'images-narrow.png'))
        self.checks.append('responsive: desktop/short/tablet/narrow, 1100/1101 + 880/881 + 539/540 boundaries, 320px reachability/hit testing, preview bounds, no page overflow')

    def startup(self):
        for suffix in ['app.css','elm.js','bridge.js']:
            self.page.route('**/'+suffix,lambda route:route.fulfill(status=503,body='Controlled asset failure'))
            self.page.goto(args.url)
            expect(self.page.locator('#startup-retry')).to_be_visible()
            self.page.unroute('**/'+suffix)
            self.page.locator('#startup-retry').click()
            expect(self.button('Browse files')).to_be_visible()
        pending=[]
        self.page.route('**/elm.js',lambda route:pending.append((route,route.fetch())))
        self.page.goto(args.url,wait_until='domcontentloaded')
        self.page.wait_for_timeout(200)
        expect(self.page.locator('#app-startup')).to_be_hidden()
        expect(self.page.locator('#app-startup')).to_be_visible(timeout=1500)
        expect(self.page.locator('#startup-retry')).to_be_hidden()
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/elm.js')
        expect(self.button('Browse files')).to_be_visible()
        self.checks.append('startup: CSS, Elm bundle, and bridge failure + retry')

    def finish(self):
        assert not self.errors, self.errors
        assert all(1 <= size <= 4 for size in self.batch_sizes), self.batch_sizes
        (self.out/'results.json').write_text(json.dumps({'browser':self.name,'version':self.browser.version,'checks':self.checks,'previewBatchSizes':self.batch_sizes},indent=2))
        print(self.name+': PASS\n'+'\n'.join('  '+check for check in self.checks),flush=True)
        for source in set(self.source_ids):
            self.context.request.delete(args.url+'/gang-up/sources/'+source)
        self.context.close()


with sync_playwright() as playwright:
    for name in args.browsers.split(','):
        browser=getattr(playwright,name).launch(headless=True)
        suite=Suite(browser,name)
        try:
            for check in args.checks.split(','):
                print(f'{name}: {check}',flush=True)
                getattr(suite,check)()
            suite.finish()
        except Exception:
            suite.page.screenshot(path=str(suite.out/'failure.png'))
            (suite.out/'failure-state.txt').write_text(suite.page.locator('body').inner_text())
            raise
        finally:
            browser.close()
