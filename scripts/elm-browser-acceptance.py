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
parser.add_argument('--checks', default='workspace_controls,notifications,theme,general,workspace_animation,recovery,intake_and_keyboard,finished_size_defaults,setup_tabs,setup_geometry,setup_polish,copy_quantities,artwork_toolbar,preview_toolbar,preset_toolbar,impression_selection,artwork_rotation,fitting,mixed_and_saved,preview_recovery,lifecycle,responsive,startup')
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
five_by_seven = pdf('five-by-seven.pdf', ['5x7 ART'], [(360, 504)])
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
        if name == 'Clear':
            return self.workspace_command('Clear workspace')
        if name.startswith('Move ') and name.rsplit(' ', 1)[-1] in ['up', 'down']:
            filename, direction = name[5:].rsplit(' ', 1)
            name = 'Move ' + direction + ': ' + filename
        elif name.startswith('Remove '):
            name = 'Remove: ' + name[7:]
        return self.page.get_by_role('button', name=name, exact=True).or_(self.page.get_by_role('radio', name=name, exact=True))

    def workspace_command(self, name):
        trigger = self.page.get_by_role('button', name='Workspace', exact=True)
        if trigger.get_attribute('aria-expanded') != 'true':
            trigger.click()
        return self.page.get_by_role('menuitem', name=name, exact=True)

    def expect_file(self, name):
        selected = self.page.locator('.setup-stepper [aria-selected=true]')
        previous = selected.inner_text() if selected.count() else None
        if previous and previous != 'Size':
            self.page.get_by_role('tab', name='Size', exact=True).evaluate('button => button.click()')
        expect(self.page.locator('.da-file-list__name')).to_have_text(name)
        if previous and previous != 'Size':
            self.page.get_by_role('tab', name=previous, exact=True).evaluate('button => button.click()')

    def toggle_theme(self):
        self.page.get_by_role('switch', name='Dark mode').click()

    def select(self, files, append=False):
        if isinstance(files, pathlib.Path):
            files = [files]
        if self.page.get_by_role('button', name='Browse files', exact=True).count():
            trigger = self.button('Browse files')
        else:
            file_label = 'artwork' if self.page.locator('.ready-card.imposing').count() else 'files'
            trigger = self.workspace_command(('Add ' if append else 'Replace ') + file_label)
        with self.page.expect_file_chooser() as chooser:
            trigger.click()
        chooser.value.set_files([str(path) for path in files])

    def idle(self):
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        expect(self.page.get_by_role('button', name='Cancel', exact=True)).to_have_count(0, timeout=60000)
        expect(self.page.get_by_role('button', name='Cancel inspection', exact=True)).to_have_count(0, timeout=60000)
        expect(self.page.locator('[data-layout-state=pending]')).to_have_count(0, timeout=60000)
        expect(self.page.locator('.preview-cache-status').filter(has_text='Updating preview')).to_have_count(0, timeout=60000)

    def close_quantities(self):
        self.button('Done').click()
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)
        self.idle()

    def wait_pending(self, pending):
        deadline = time.monotonic() + 15
        while not pending and time.monotonic() < deadline:
            # Yield to Playwright's route handlers until the real backend has
            # returned the response this recovery test is deliberately holding.
            self.page.wait_for_timeout(20)
        assert pending, 'Expected a held backend response before cancellation'

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
        self.page.get_by_role('combobox', name='Tool', exact=True).click()
        self.page.get_by_role('option', name=name, exact=True).click()

    def workspace_controls(self):
        self.fresh()
        self.select(three)
        self.idle()
        expect(self.page.locator('.app-file-context')).to_have_count(0)
        expect(self.page.locator('.app-header-actions #workspace-actions-trigger, .app-header-actions .da-theme-toggle')).to_have_count(2)
        trigger = self.button('Workspace')
        toggle = self.page.get_by_role('switch', name='Dark mode')
        expect(toggle).to_be_visible()
        workspace_box, theme_box = trigger.bounding_box(), toggle.bounding_box()
        assert theme_box['x'] >= workspace_box['x'] + workspace_box['width']
        assert abs(theme_box['height'] - workspace_box['height']) < 1
        trigger.focus()
        trigger.press('Enter')
        menu = self.page.get_by_role('menu', name='Workspace actions')
        expect(menu).to_be_visible()
        expect(menu.get_by_role('menuitem')).to_have_count(3)
        expect(menu.get_by_role('menuitem', name='Add files')).to_be_focused()
        self.page.keyboard.press('End')
        expect(menu.get_by_role('menuitem').last).to_be_focused()
        self.page.keyboard.press('Escape')
        expect(trigger).to_be_focused()
        expect(menu).not_to_be_visible()
        self.workspace_command('Clear workspace').click()
        expect(self.page.get_by_role('dialog', name='Clear all files?')).to_be_visible()
        self.button('Keep working').click()
        expect(trigger).to_be_focused()
        expect(self.page.locator('.da-file-list__name')).to_have_text('three.pdf')
        before = self.page.locator('html').get_attribute('data-theme')
        self.toggle_theme()
        expect(self.page.locator('html')).to_have_attribute('data-theme', 'light' if before == 'dark' else 'dark')
        self.button('Page range').click()
        expect(self.page.get_by_role('dialog', name='Choose a page range')).to_be_visible()
        self.page.get_by_label('Pages', exact=True).fill('2-3')
        self.button('Apply range').click()
        expect(self.button('Page range')).to_have_attribute('aria-pressed', 'true')
        self.button('All pages').click()
        expect(self.button('All pages')).to_have_attribute('aria-pressed', 'true')
        frame = self.page.locator('.page-selection-actions')
        expect(frame).to_have_css('background-color', 'rgba(0, 0, 0, 0)')
        expect(frame).to_have_css('padding', '0px')
        self.switch('Impose artwork')
        self.idle()
        sizes = self.page.get_by_role('tablist', name='Print setup options').get_by_role('tab').evaluate_all('(tabs) => tabs.map(t => {const b=t.getBoundingClientRect(); return [b.width,b.height]})')
        assert all(abs(size[0]-sizes[0][0]) < 1 and abs(size[1]-sizes[0][1]) < 1 for size in sizes), sizes
        self.workspace_command('Add artwork')
        expect(menu.get_by_role('menuitem', name='Replace artwork')).to_be_visible()
        self.page.keyboard.press('Escape')
        self.checks.append('workspace controls: DA command menu with adjacent theme toggle, keyboard navigation/dismissal, clear cancellation/focus, page range/all pages, equal setup tabs')

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
            if saved == 'blocked':
                expect(page.get_by_text('Theme changed for this tab. Your browser could not save the preference.', exact=True)).to_be_visible()
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
        if self.page.viewport_size['width'] > 1100:
            expect(self.page.locator('.sheet-svg')).to_be_visible()
        else:
            # The mobile Setup tab intentionally hides the ready preview.
            expect(self.page.locator('.sheet-svg')).to_be_attached()

    def continue_to(self, step):
        self.step(step)
        self.idle()

    def step(self, name):
        tab = self.page.locator('.setup-stepper').get_by_role('tab', name=name, exact=True)
        tab.click()
        # Step navigation restores focus on the next animation frame. Opening a
        # popover before that completes makes its normal outside-focus handler
        # close it again. Wait for rendering, without waiting for layout work.
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        expect(tab).to_be_focused()

    def dropdown(self, name, value):
        if name == 'Apply preset' and not self.page.locator('.elm-presets-menu .da-popover').is_visible():
            self.presets()
        labels = {
            '12x18': '12 × 18 in', '8.5x11': '8.5 × 11 in',
            '11x17': '11 × 17 in', '13x19': '13 × 19 in', 'custom': 'Custom size',
            'single': 'Single-sided', 'double': 'Double-sided',
            'longEdge': 'Long edge', 'shortEdge': 'Short edge',
        }
        trigger = self.page.get_by_role('combobox', name=name, exact=True)
        if trigger.get_attribute('aria-expanded') != 'true':
            trigger.click()
        self.page.get_by_role('option', name=labels.get(value, value), exact=True).click()
        expect(trigger).to_have_attribute('aria-expanded', 'false')

    def preset_option(self, name):
        return self.page.locator('#apply-preset-listbox [role=option]').filter(has_text=name)

    def set_fitting(self, mode):
        control = self.page.get_by_role('group', name='Artwork fitting', exact=True)
        radio = control.get_by_role('radio', name=mode, exact=True)
        radio.check()
        expect(radio).to_be_checked()
        expect(control.locator('input:checked')).to_have_count(1)

    def presets(self):
        # Let pending Elm updates and native popover toggles settle before
        # deciding whether to open; otherwise a second click can close it.
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        trigger = self.page.get_by_role('button', name='Presets', exact=True)
        if trigger.get_attribute('aria-expanded') != 'true':
            trigger.click()
        menu = self.page.locator('.elm-presets-menu')
        expect(menu.locator('.da-popover')).to_be_visible()
        expect(trigger).to_have_attribute('aria-expanded', 'true')
        return menu

    def close_presets(self):
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        trigger = self.page.get_by_role('button', name='Presets', exact=True)
        if trigger.get_attribute('aria-expanded') == 'true':
            trigger.click()
        expect(self.page.locator('.elm-presets-menu .da-popover')).to_be_hidden()
        expect(trigger).to_have_attribute('aria-expanded', 'false')
        self.page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')

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
        self.button('Move b.pdf up').press('Enter')
        path = self.download('Download PDF', 'merged.pdf')
        self.assert_pdf(path, ['SECOND', 'FIRST'], [(288,216), (216,144)])
        self.button('Remove a.pdf').click()
        expect(self.page.locator('.da-reorderable__item')).to_have_count(1)
        self.select(a_pdf, append=True)
        self.idle()
        expect(self.page.locator('.da-reorderable__item')).to_have_count(2)
        self.select([stripe, small_jpeg])
        self.idle()
        expect(self.page.get_by_role('combobox', name='Tool', exact=True)).to_have_text('Images to PDF')
        self.button('Move small.jpg up').click()
        path = self.download('Create PDF', 'images.pdf')
        with fitz.open(path) as document:
            assert len(document) == 2
            assert tuple(document[0].rect)[2:] == (72, 144)
            assert tuple(document[1].rect)[2:] == (216, 120)
            color = document[0].get_pixmap().pixel(30,30)
            assert color[0] > 220 and color[1] > 220 and color[2] < 30, color
        if self.page.locator('html').get_attribute('data-theme') == 'dark':
            self.toggle_theme()
        expect(self.page.locator('html')).to_have_attribute('data-theme','light')
        self.toggle_theme()
        expect(self.page.locator('html')).to_have_attribute('data-theme','dark')
        self.page.reload()
        expect(self.page.locator('html')).to_have_attribute('data-theme','dark')
        self.checks.append('general: PNG/JPEG + all resolutions, extraction modes/chunks/order, PDF merge/order/dimensions, natural image pages/order, theme persistence')

    def notifications(self):
        self.fresh()
        self.select(three)
        self.idle()
        self.page.wait_for_timeout(250)
        def bounds():
            return self.page.locator('.ready-card').bounding_box()
        baseline = bounds()
        def stable():
            current = bounds()
            assert all(abs(current[key]-baseline[key]) < 1 for key in baseline), (baseline,current)
        def corner():
            region = self.page.locator('.toast-region')
            expect(region).to_be_visible()
            box = region.bounding_box()
            viewport = self.page.viewport_size
            assert box['x'] >= 0 and box['y'] >= 0, box
            assert abs(viewport['width']-box['x']-box['width']) <= 21, box
            assert abs(viewport['height']-box['y']-box['height']) <= 21, box
            assert self.page.locator('.toast-region').evaluate("el=>getComputedStyle(el).position") == 'fixed'
        pending = []
        self.page.route('**/jobs',lambda route: pending.append(route))
        self.button('Download images').click()
        expect(self.page.locator('.toast-progress')).to_be_visible()
        self.page.wait_for_timeout(250)
        stable()
        corner()
        self.page.screenshot(path=str(self.out/'toast-progress.png'))
        self.button('Cancel').click()
        expect(self.page.locator('.toast-progress')).to_have_count(0)
        expect(self.page.locator('.toast')).to_contain_text('Cancelled')
        stable()
        self.button('Dismiss notification').focus()
        self.button('Dismiss notification').press('Enter')
        expect(self.page.locator('.toast')).to_have_count(0)
        for route in pending:
            route.fulfill(status=503,body='Cancelled upload')
        self.page.unroute('**/jobs')
        self.page.route('**/jobs',lambda route: route.fulfill(status=503,body='Controlled toast failure'))
        self.button('Download images').click()
        expect(self.page.get_by_role('alert')).to_have_text('Controlled toast failure')
        self.page.wait_for_timeout(6500)
        expect(self.page.get_by_role('alert')).to_be_visible()
        stable()
        corner()
        self.page.unroute('**/jobs')
        with self.page.expect_download(timeout=60000) as download:
            self.button('Retry').click()
        download.value.save_as(str(self.out/'toast-retry.zip'))
        self.idle()
        expect(self.page.locator('.toast')).to_contain_text('was sent to your browser')
        stable()
        corner()
        expect(self.page.locator('.toast')).to_have_count(0,timeout=10000)
        self.page.emulate_media(reduced_motion='reduce')
        for theme in ['light','dark']:
            if self.page.locator('html').get_attribute('data-theme') != theme:
                self.toggle_theme()
            for viewport in [{'width':1366,'height':900},{'width':390,'height':700}]:
                self.page.set_viewport_size(viewport)
                self.page.route('**/jobs',lambda route: route.fulfill(status=503,body='Controlled toast failure'))
                self.button('Download images').click()
                expect(self.page.get_by_role('alert')).to_have_text('Controlled toast failure')
                corner()
                toast = self.page.locator('.toast')
                assert toast.evaluate("el=>getComputedStyle(el).animationName") == 'none'
                self.page.screenshot(path=str(self.out/f'toast-{theme}-{viewport["width"]}.png'))
                self.button('Dismiss notification').click()
                expect(toast).to_have_count(0)
                self.page.unroute('**/jobs')
        self.page.emulate_media(reduced_motion='no-preference')
        self.page.set_viewport_size({'width':1366,'height':900})
        self.checks.append('notifications: fixed bottom-right feedback, stable progress/error/download geometry, cancellation, persistent errors, keyboard dismissal, retry, confirmation expiry, both themes and mobile, reduced motion')

    def recovery(self):
        self.fresh()
        self.select(three)
        self.idle()
        self.button('JPEG').click()
        self.select(corrupt)
        expect(self.page.get_by_role('alert')).to_contain_text('')
        self.expect_file('three.pdf')
        expect(self.button('JPEG')).to_be_checked()
        self.select(a_pdf)
        self.idle()
        self.expect_file('a.pdf')
        pending = []
        self.page.route('**/pdf/inspect', lambda route: pending.append((route, route.fetch())))
        self.select(three)
        self.button('Cancel inspection').wait_for()
        self.wait_pending(pending)
        self.button('Cancel inspection').click()
        for route, response in pending:
            try: route.fulfill(response=response)
            except Exception: pass  # A native Elm Http.cancel may have already aborted it.
        self.page.unroute('**/pdf/inspect')
        self.page.wait_for_timeout(200)
        self.expect_file('a.pdf')
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
        self.wait_pending(pending)
        self.button('Cancel').click()
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/jobs')
        self.page.wait_for_timeout(300)
        self.expect_file('three.pdf')
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
        moving=self.page.locator('.da-reorderable__item').filter(has_text='b.pdf')
        moving.focus()
        moving.press('Alt+ArrowUp')
        expect(moving).to_be_focused()
        expect(self.page.locator('.da-reorderable__item').first).to_contain_text('b.pdf')
        moving.press('Alt+ArrowDown')
        expect(moving).to_be_focused()
        moving.press('Alt+ArrowUp')
        path=self.download('Download PDF','keyboard-merge.pdf')
        self.assert_pdf(path,['SECOND','FIRST'])
        # Pointer reordering uses the same stable file identity.
        source=self.page.locator('.da-reorderable__item').filter(has_text='a.pdf')
        target=self.page.locator('.da-reorderable__item').filter(has_text='b.pdf')
        # Drag from the filename area, away from the interactive row buttons.
        source.drag_to(target, source_position={'x': 45, 'y': 18}, target_position={'x': 45, 'y': 18})
        expect(self.page.locator('.da-reorderable__item').first).to_contain_text('a.pdf')
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
        expect(self.page.locator('#finished-width')).to_have_value('3')
        expect(self.page.locator('#finished-height')).to_have_value('2')
        expect(self.page.get_by_role('combobox', name='Finished orientation', exact=True)).to_be_enabled()
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.idle()
        # Automatic fitting may place these pieces portrait. Start explicitly
        # landscape so Home commits a different orientation in the keyboard test.
        self.dropdown('Finished orientation', 'Landscape')
        self.idle()
        orientation = self.page.get_by_role('combobox', name='Finished orientation', exact=True)
        orientation.focus()
        orientation.press('Home')
        expect(orientation).to_have_attribute('aria-expanded', 'true')
        orientation.press('Escape')
        expect(orientation).to_have_attribute('aria-expanded', 'false')
        expect(self.page.locator('#finished-width')).to_have_value('3')
        orientation.press('Home')
        orientation.press('Enter')
        expect(self.page.locator('#finished-width')).to_have_value('2')
        self.page.get_by_role('combobox', name='Finished orientation', exact=True).click()
        self.page.get_by_role('option', name='Landscape', exact=True).click()
        self.idle()
        assert len(self.layouts[-1]['pagePlans'])==3
        expect(self.page.get_by_label('Width (in)', exact=True)).to_have_value('3')
        expect(self.page.get_by_label('Height (in)', exact=True)).to_have_value('2')
        expect(self.page.get_by_text('Detected artwork details', exact=True)).to_have_count(0)
        expect(self.button('Repeat pages')).to_have_count(0)
        expect(self.page.get_by_role('heading', name='Artwork files', exact=True)).to_be_visible()
        self.button('Move small.jpg up').click()
        self.idle()
        self.button('Remove stripes.png').click()
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
        self.checks.append('intake/keyboard: native file drops and append, keyboard/pointer ordering + stable focus, dialog Escape focus, mixed PDF/PNG/JPEG preparation/reorder/remove/output, automatic dimensions and finished orientation')

    def finished_size_defaults(self):
        self.fresh()
        self.select(five_by_seven)
        self.idle()
        self.switch('Impose artwork')
        self.idle()
        expect(self.page.locator('#finished-width')).to_have_value('5')
        expect(self.page.locator('#finished-height')).to_have_value('7')
        expect(self.page.get_by_role('combobox', name='Finished orientation', exact=True)).to_have_text('Portrait')
        assert self.layouts[-1]['finishedCutSize'] == {'width': 5, 'height': 7}
        self.step('Bleed')
        path = self.download('Download imposed PDF', 'autofilled-5x7.pdf')
        with fitz.open(path) as document:
            assert '5x7 ART' in document[0].get_text()
        self.step('Size')
        self.select(b_pdf)
        self.idle()
        expect(self.page.locator('#finished-width')).to_have_value('4')
        expect(self.page.locator('#finished-height')).to_have_value('3')
        self.page.locator('#finished-width').fill('3.5')
        self.page.locator('#finished-height').fill('2')
        self.select(five_by_seven)
        self.idle()
        expect(self.page.locator('#finished-width')).to_have_value('3.5')
        expect(self.page.locator('#finished-height')).to_have_value('2')
        self.fresh()
        self.select(stripe)
        self.idle()
        self.switch('Impose artwork')
        self.idle()
        expect(self.page.locator('#finished-width')).to_have_value('3')
        assert abs(float(self.page.locator('#finished-height').input_value()) - 500 / 300) < .0001
        self.checks.append('finished-size defaults: 5x7 PDF autofill + export, original portrait orientation, replacement updates untouched defaults, manual edits retained, image dimensions at 300 DPI')

    def setup_tabs(self):
        self.fresh()
        self.select(stripe)
        self.idle()
        self.switch('Impose artwork')
        tabs = self.page.get_by_role('tablist', name='Print setup options')
        expect(tabs.get_by_role('tab')).to_have_count(3)
        expect(tabs.get_by_role('tab')).to_have_text(['Size', 'Sheet', 'Bleed'])
        self.step('Size')
        panel = self.page.get_by_role('tabpanel', name='Size', exact=True)
        expect(panel.get_by_role('heading', name='Arrangement', exact=True)).to_be_visible()
        self.button('Custom grid').click()
        self.page.get_by_label('Rows', exact=True).fill('1')
        self.page.get_by_label('Columns', exact=True).fill('2')
        self.step('Bleed')
        self.step('Size')
        expect(self.page.get_by_label('Rows', exact=True)).to_have_value('1')
        expect(self.page.get_by_label('Columns', exact=True)).to_have_value('2')
        for name in ['Bleed', 'Sheet', 'Size']:
            tab = tabs.get_by_role('tab', name=name, exact=True)
            expect(tab).to_be_enabled()
            tab.click()
            expect(tab).to_have_attribute('aria-selected', 'true')
            expect(tab).to_be_focused()
            expect(self.page.get_by_role('tabpanel', name=name, exact=True)).to_be_visible()
        self.page.locator('#finished-width').fill('4.')
        expect(self.button('Continue')).to_be_enabled()
        self.button('Continue').click()
        expect(tabs.get_by_role('tab', name='Sheet', exact=True)).to_be_focused()
        self.step('Bleed')
        expect(self.button('Download imposed PDF')).to_be_disabled()
        self.step('Size')
        expect(self.page.locator('#finished-width')).to_have_value('4.')
        expect(self.page.locator('#finished-width')).to_have_attribute('aria-invalid', 'true')
        keys = [('ArrowLeft', 'Bleed'), ('ArrowRight', 'Size'), ('End', 'Bleed'), ('Home', 'Size'), ('ArrowRight', 'Sheet')]
        tabs.get_by_role('tab', name='Size', exact=True).focus()
        for key, name in keys:
            self.page.keyboard.press(key)
            tab = tabs.get_by_role('tab', name=name, exact=True)
            expect(tab).to_be_focused()
            expect(tab).to_have_attribute('aria-selected', 'true')
        self.step('Size')
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.step('Bleed')
        self.idle()
        expect(self.button('Download imposed PDF')).to_be_enabled()
        control = self.page.get_by_role('group', name='Artwork fitting', exact=True)
        control.get_by_role('radio', name='Stretch', exact=True).focus()
        self.page.keyboard.press('Space')
        expect(control.get_by_role('radio', name='Stretch', exact=True)).to_be_checked()
        for mode in ['Fill', 'Stretch', 'Fit']:
            self.set_fitting(mode)
            self.idle()
        self.page.screenshot(path=str(self.out/'setup-tabs.png'))
        self.checks.append('setup tabs: immediate out-of-order access, drafts retained, export validation, arrow/Home/End navigation, native fitting keyboard access')

    def setup_geometry(self):
        self.fresh()
        self.impose(stripe)
        self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
        for width, height in [(1366, 900), (1366, 560), (800, 900), (390, 700), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            if width <= 1100:
                self.page.get_by_role('tab', name='Setup', exact=True).click()
            self.step('Size')
            self.page.wait_for_timeout(80)
            # Sample actual rendered frames: a settled-only check misses snaps
            # caused by focus scrolling or an extra footer on the final tab.
            frames = self.page.evaluate('''() => new Promise(resolve => {
              const bounds = selector => {
                const r = document.querySelector(selector).getBoundingClientRect();
                return {x:r.x, y:r.y, width:r.width, height:r.height};
              };
              const snapshot = () => ({
                header:bounds('.app-header'), card:bounds('.ready-card'),
                tabs:bounds('.setup-stepper'), fields:bounds('.gang-setup-fields'),
                footer:bounds('.elm-setup-actions'),
                action:bounds('.setup-continue-button'),
                back:document.querySelector('.elm-setup-actions .ghost-button')?.getBoundingClientRect().x,
                step:document.querySelector('.setup-stepper [aria-selected=true] .setup-step-label').textContent,
                scrollX, scrollY
              });
              const frames = [snapshot()];
              const tabs = [...document.querySelectorAll('.setup-stepper [role=tab]')];
              const targets = [1, 2, 0, 2, 1, 0];
              let index = 0, tick = 0;
              const sample = () => {
                if (tick % 5 === 0 && index < targets.length) {
                  const target = targets[index++];
                  if (index <= 2) document.querySelector('.setup-continue-button').click();
                  else if (index >= 5) document.querySelector('.setup-back-button').click();
                  else tabs[target].click();
                }
                frames.push(snapshot());
                if (++tick < targets.length * 5 + 5) requestAnimationFrame(sample);
                else resolve(frames);
              };
              requestAnimationFrame(sample);
            })''')
            (self.out/f'setup-geometry-{width}x{height}.json').write_text(json.dumps(frames, indent=2))
            first = frames[0]
            assert self.page.evaluate('''() => {
              const color = selector => getComputedStyle(document.querySelector(selector)).backgroundColor;
              return color('.elm-setup') === color('.setup-stepper') &&
                     color('.elm-setup') === color('.elm-setup-actions');
            }'''), (width, height, 'Setup navigation must share the rail background')
            assert {frame['step'] for frame in frames} == {'Size', 'Sheet', 'Bleed'}, (width, height, 'Steps did not all render')
            for frame in frames:
                footer, action = frame['footer'], frame['action']
                assert abs(action['x'] + action['width'] - (footer['x'] + footer['width'] - 12)) < 1, (width, height, 'Primary action must stay right', frame)
                if frame.get('back') is not None:
                    assert abs(frame['back'] - footer['x'] - 12) < 1, (width, height, 'Back must stay left', frame)
                for part in ['header', 'card', 'tabs', 'fields', 'footer']:
                    assert all(abs(frame[part][key] - first[part][key]) < 1 for key in first[part]), (width, height, part, frames)
                assert abs(action['y'] - first['action']['y']) < 1, (width, height, 'Action moves vertically', frames)
                assert frame['scrollX'] == first['scrollX'] and frame['scrollY'] == first['scrollY'], (width, height, 'Focus scrolls the page', frames)
            # Long content scrolls inside the rail without moving navigation.
            expect(self.page.get_by_role('heading', name='Artwork files', exact=True)).to_be_visible()
            self.page.locator('.gang-setup-fields').evaluate('e => e.scrollTop = e.scrollHeight')
            footer = self.page.locator('.elm-setup-actions').bounding_box()
            assert abs(footer['y'] - first['footer']['y']) < 1
            self.button('Continue').click()
            expect(self.button('Repeat pages')).to_be_visible()
            assert self.page.get_by_role('heading', name='Quantity and sheet', exact=True).evaluate('''e => {
              const r = e.getBoundingClientRect(), region = e.closest('.gang-setup-fields').getBoundingClientRect();
              return r.y >= region.y && r.bottom <= region.bottom;
            }'''), (width, height, 'New step retained the previous scroll position')
            self.page.locator('.gang-setup-fields').evaluate('e => e.scrollTop = e.scrollHeight')
            expect(self.page.get_by_text('Advanced sheet settings', exact=True)).to_be_visible()
            footer = self.page.locator('.elm-setup-actions').bounding_box()
            assert abs(footer['y'] - first['footer']['y']) < 1, (width, height, 'Combined Sheet settings move the footer')
            self.step('Bleed')
            self.presets()
            self.page.locator('.gang-setup-fields').evaluate('e => e.scrollTop = e.scrollHeight')
            footer = self.page.locator('.elm-setup-actions').bounding_box()
            assert abs(footer['y'] - first['footer']['y']) < 1, (width, height, 'Preset menu moves the footer')
            self.close_presets()
            action = self.button('Download imposed PDF')
            assert action.evaluate('''e => {
              const r = e.getBoundingClientRect();
              return r.y >= 0 && r.bottom <= innerHeight && e.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2));
            }'''), (width, height, 'Final action is clipped')
            self.page.screenshot(path=str(self.out/f'setup-stable-{width}x{height}.png'))
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('setup geometry: primary action stays right, Back stays left, stable tabs/scroller/footer across all steps and rapid reversal, page focus and rail scrolling at desktop/short/tablet/390px/320px')

    def setup_polish(self):
        self.fresh()
        long_pdf = pdf('customer-artwork-with-a-very-long-filename-for-printing.pdf', ['LONG NAME'])
        self.impose([a_pdf, long_pdf, b_pdf])
        self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
        for theme in ['dark', 'light']:
            if self.page.locator('html').get_attribute('data-theme') != theme:
                self.toggle_theme()
            for width, height in [(1366, 900), (1366, 560), (800, 900), (390, 700), (320, 568)]:
                self.page.set_viewport_size({'width': width, 'height': height})
                if width <= 1100:
                    self.page.get_by_role('tab', name='Setup', exact=True).click()
                self.step('Size')
                self.idle()
                if width > 1100:
                    tabs = self.page.locator('.setup-stepper').bounding_box()
                    toolbar = self.page.locator('.elm-toolbar').bounding_box()
                    setup = self.page.locator('.elm-setup').bounding_box()
                    assert abs(tabs['y'] - toolbar['y']) < 1, (theme, width, tabs, toolbar)
                    assert abs(tabs['y'] + tabs['height'] - toolbar['y'] - toolbar['height']) < 1
                    assert abs(tabs['x'] - setup['x']) < 1
                    side_border = self.page.locator('.elm-setup').evaluate('e => parseFloat(getComputedStyle(e).borderRightWidth)')
                    assert abs(tabs['x'] + tabs['width'] + side_border - toolbar['x']) < 1
                rows = self.page.locator('.impose-artwork-files .da-reorderable__item')
                expect(rows).to_have_count(3)
                dimensions = rows.evaluate_all('''rows => rows.map(row => {
                  const r = row.getBoundingClientRect(), s = getComputedStyle(row);
                  const name = row.querySelector('.da-file-list__name'), n = name.getBoundingClientRect();
                  return {x:r.x, y:r.y, width:r.width, height:r.height,
                    radius:parseFloat(s.borderTopLeftRadius), bottomRadius:parseFloat(s.borderBottomRightRadius),
                    title:name.title, ellipsis:getComputedStyle(name).textOverflow,
                    nameWidth:n.width, overflow:row.scrollWidth > row.clientWidth + 1,
                    contained:[...row.querySelectorAll('button')].every(button => {
                      const b = button.getBoundingClientRect();
                      return b.x >= r.x + 7 && b.right <= r.right - 7 && b.y >= r.y && b.bottom <= r.bottom && Math.abs((b.y + b.height / 2) - (r.y + r.height / 2)) < 1;
                    })};
                })''')
                for index, row in enumerate(dimensions):
                    assert row['height'] <= 80, row
                    assert row['contained'] and not row['overflow'] and row['nameWidth'] >= 30, row
                    assert row['ellipsis'] == 'ellipsis' and row['title'], row
                    if index:
                        previous = dimensions[index - 1]
                        assert row['y'] >= previous['y'] + previous['height'] - 1, dimensions
                    rows.nth(index).scroll_into_view_if_needed()
                    expect(rows.nth(index).get_by_role('button', name='Remove: ' + row['title'], exact=True)).to_be_visible()
                expect(self.button('Move a.pdf up')).to_be_disabled()
                expect(self.button('Move b.pdf down')).to_be_disabled()
                self.page.screenshot(path=str(self.out/f'artwork-rows-{theme}-{width}x{height}.png'))
                back, forward = self.button('Back'), self.button('Continue')
                first_footer = self.page.locator('.elm-setup-actions').bounding_box()
                for index, name in enumerate(['Size', 'Sheet', 'Bleed']):
                    expect(self.page.get_by_role('tabpanel', name=name, exact=True)).to_be_visible()
                    for arrow in [back, forward]:
                        expect(arrow).to_be_visible()
                        assert arrow.inner_text() == ''
                        expect(arrow.locator('svg')).to_have_attribute('aria-hidden', 'true')
                        assert arrow.get_attribute('title')
                    expect(back).to_be_disabled() if index == 0 else expect(back).to_be_enabled()
                    expect(forward).to_be_disabled() if index == 2 else expect(forward).to_be_enabled()
                    footer = self.page.locator('.elm-setup-actions').bounding_box()
                    assert all(abs(footer[key] - first_footer[key]) < 1 for key in footer), (theme, width, name)
                    if index == 0:
                        back.evaluate('e => e.click()')
                        expect(self.page.get_by_role('tab', name='Size', exact=True)).to_have_attribute('aria-selected', 'true')
                    if index < 2:
                        forward.click()
                    else:
                        forward.evaluate('e => e.click()')
                        expect(self.page.get_by_role('tab', name='Bleed', exact=True)).to_have_attribute('aria-selected', 'true')
                        expect(self.button('Download imposed PDF')).to_be_visible()
                self.page.screenshot(path=str(self.out/f'setup-arrows-{theme}-{width}x{height}.png'))
                for name in ['Sheet', 'Size']:
                    back.click()
                    expect(self.page.get_by_role('tab', name=name, exact=True)).to_be_focused()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        # Exercise the polished cards' actual file actions, including focus after reorder.
        self.button('Move ' + long_pdf.name + ' up').click()
        self.idle()
        expect(rows.first).to_contain_text(long_pdf.name)
        moving = rows.first
        moving.focus()
        moving.press('Alt+ArrowDown')
        self.idle()
        expect(moving).to_contain_text('a.pdf')
        expect(rows.nth(1)).to_be_focused()
        self.button('Remove ' + long_pdf.name).click()
        self.idle()
        expect(rows).to_have_count(2)
        expect(rows.filter(has_text=long_pdf.name)).to_have_count(0)
        pending = []
        self.page.route('**/pdf/inspect', lambda route: pending.append((route, route.fetch())))
        try:
            self.select(long_pdf, append=True)
            expect(self.button('Cancel inspection')).to_be_visible()
            expect(self.button('Back')).to_be_disabled()
            expect(self.button('Continue')).to_be_disabled()
            self.button('Continue').evaluate('e => e.click()')
            expect(self.page.get_by_role('tab', name='Size', exact=True)).to_have_attribute('aria-selected', 'true')
        finally:
            for route, response in pending:
                route.fulfill(response=response)
            self.page.unroute('**/pdf/inspect')
        self.idle()
        expect(self.button('Continue')).to_be_enabled()
        self.checks.append('setup polish: continuous desktop header divider; rounded, spaced artwork cards and long filenames; reorder/remove and keyboard focus; persistent accessible arrows, disabled endpoints, stable footer and separate download in both themes at desktop/short/tablet/390px/320px')

    def copy_quantities(self):
        for theme in ['light', 'dark']:
            for width, height in [(1366, 900), (620, 700), (390, 700), (320, 568)]:
                self.page.set_viewport_size({'width': width, 'height': height})
                self.fresh()
                self.impose(six)
                if self.page.locator('html').get_attribute('data-theme') != theme:
                    self.toggle_theme()
                expect(self.page.locator('html')).to_have_attribute('data-theme', theme)
                if width <= 1100:
                    self.page.get_by_role('tab', name='Setup', exact=True).click()
                self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
                tabs = self.page.locator('.setup-stepper')
                tabs.evaluate('''nav => {
                    const buttons = [...nav.querySelectorAll('button')];
                    const widths = buttons.map(button => button.getBoundingClientRect().width);
                    if (Math.max(...widths) - Math.min(...widths) > 1) throw new Error('Unequal setup tabs');
                    for (const button of buttons) {
                        const bounds = button.getBoundingClientRect();
                        const range = document.createRange();
                        range.selectNodeContents(button.querySelector('.setup-step-label'));
                        for (const label of range.getClientRects()) {
                            if (label.left < bounds.left + 2 || label.right > bounds.right - 2)
                                throw new Error('Setup label clips: ' + button.textContent);
                        }
                    }
                }''')
                self.step('Sheet')
                self.button('Repeat pages').click()
                expect(self.page.locator('#workspace-dialog')).to_be_visible()
                self.close_quantities()
                opener = self.button('Edit copy quantities')
                for printing, quantities in [('single', [3] * 6), ('double', [3] * 3)]:
                    self.dropdown('Printing', printing)
                    self.idle()
                    opener.click()
                    dialog = self.page.locator('#workspace-dialog')
                    bulk = self.page.locator('#bulk-copy-quantity')
                    expect(bulk).to_be_focused()
                    bulk.fill('-1')
                    bulk.press('Enter')
                    expect(dialog).to_be_visible()
                    expect(self.button('Apply to all')).to_be_disabled()
                    bulk.fill('3')
                    # A stale individual draft must be replaced by the bulk value.
                    dialog.locator('.quantity-dialog-list input').first.fill('8')
                    bulk.focus()
                    dialog.locator('form').evaluate('''form => {
                        const visible = [...form.children].filter(el => el.getBoundingClientRect().height > 0);
                        for (let index = 1; index < visible.length; index++) {
                            const previous = visible[index - 1].getBoundingClientRect();
                            const current = visible[index].getBoundingClientRect();
                            if (current.top - previous.bottom < 10) throw new Error('Dialog controls lack spacing');
                        }
                    }''')
                    self.page.screenshot(path=str(self.out/f'copy-quantities-{theme}-{width}-{printing}.png'))
                    bulk.press('Enter')
                    expect(dialog).to_have_count(0)
                    expect(opener).to_be_focused()
                    self.idle()
                    assert self.layouts[-1]['impressionQuantities'] == quantities, self.layouts[-1]
                    opener.click()
                    expect(dialog.locator('.quantity-dialog-list input').first).to_have_value('3')
                    self.button('Cancel').click()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('copy quantities: bulk Enter applies simplex and duplex values, replaces stale drafts, rejects invalid input, restores focus; dialog spacing and unclipped equal setup tabs in both themes and narrow viewports')

    def artwork_toolbar(self):
        for width, height in [(1366, 900), (1366, 560), (800, 900), (390, 700), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            self.fresh()
            self.impose(stripe)
            self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
            toolbar = self.page.locator('.elm-toolbar')
            control = toolbar.get_by_role('group', name='Artwork fitting', exact=True)
            expect(control).to_be_visible()
            expect(control.get_by_role('radio')).to_have_count(3)
            expect(control.locator('.da-radio-option label')).to_have_text(['Fit', 'Fill', 'Stretch'])
            expect(toolbar.get_by_role('combobox', name='Artwork fitting', exact=True)).to_have_count(0)
            expect(toolbar.locator('.elm-artwork-menu')).to_have_count(0)
            for label in ['Artwork rotation', 'Impression orientation', 'Adjust only selected artwork', 'Selected artwork', 'Horizontal position', 'Vertical position', 'Artwork finished width (in)', 'Artwork finished height (in)']:
                expect(toolbar.get_by_label(label, exact=True)).to_have_count(0)
            expect(toolbar.locator('.crop-anchor-grid, .elm-crop-editor')).to_have_count(0)
            for mode in ['Fill', 'Stretch', 'Fit']:
                control.scroll_into_view_if_needed()
                before = toolbar.bounding_box()
                self.set_fitting(mode)
                self.idle()
                after = toolbar.bounding_box()
                assert all(abs(after[key] - before[key]) < 1 for key in before), (width, height, mode, before, after)
                bounds = control.bounding_box()
                assert bounds['x'] >= 0 and bounds['x'] + bounds['width'] <= width + 1, bounds
            self.page.screenshot(path=str(self.out/f'artwork-fitting-{width}x{height}.png'))
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('artwork fitting: DA segmented Fit/Fill/Stretch field without a header, no Artwork disclosure or other artwork controls, stable toolbar and narrow-screen reachability')


    def preview_toolbar(self):
        self.fresh()
        self.impose(stripe)
        self.step('Sheet')
        self.button('Repeat pages').click()
        self.close_quantities()
        self.page.get_by_label('Copies', exact=True).fill('61')
        self.idle()
        toolbar = self.page.locator('.elm-toolbar')
        expect(toolbar.locator('.elm-preview-guides')).to_have_count(0)
        for name in ['Cut lines', 'Cut paths', 'Bleed lines', 'Gutters']:
            expect(self.page.get_by_role('checkbox', name=name, exact=True)).to_have_count(0)
        expect(self.page.locator('.piece-cut')).to_have_count(0)
        expect(self.page.locator('.piece-bleed')).to_have_count(0)
        expect(self.page.locator('.preview-bleed-status')).to_have_count(0)
        # Every cut edge has one sheet-spanning path, above all artwork.
        def assert_paths():
            self.page.locator('.sheet-svg').evaluate('''svg => {
          const cuts = [...svg.querySelectorAll('.piece-hit-area')];
          const paths = [...svg.querySelectorAll('.piece-cut-path')];
          const horizontal = [...new Set(cuts.flatMap(r => [+r.getAttribute('y'), +r.getAttribute('y') + +r.getAttribute('height')]))];
          const vertical = [...new Set(cuts.flatMap(r => [+r.getAttribute('x'), +r.getAttribute('x') + +r.getAttribute('width')]))];
          if (paths.length !== horizontal.length + vertical.length) throw new Error('Duplicated or missing cut paths');
          for (const y of horizontal) if (!paths.some(p => +p.getAttribute('y1') === y && +p.getAttribute('y2') === y)) throw new Error('Missing horizontal cut');
          for (const x of vertical) if (!paths.some(p => +p.getAttribute('x1') === x && +p.getAttribute('x2') === x)) throw new Error('Missing vertical cut');
          if (svg.lastElementChild.classList.value !== 'sheet-guides') throw new Error('Guides can be covered by artwork');
          for (const bleed of svg.querySelectorAll('.piece-bleed-bound')) {
            const cut = svg.querySelector('#sheet-item-' + bleed.dataset.impressionIndex + ' .piece-hit-area');
            const amount = +bleed.dataset.bleedAmount;
            if (!cut || amount <= 0) throw new Error('Bleed shown for an empty impression or zero bleed');
            for (const [key, expected] of [
              ['x', +cut.getAttribute('x') - amount], ['y', +cut.getAttribute('y') - amount],
              ['width', +cut.getAttribute('width') + 2 * amount], ['height', +cut.getAttribute('height') + 2 * amount]
            ]) if (Math.abs(+bleed.getAttribute(key) - expected) > .00001) throw new Error('Incorrect bleed boundary: ' + key);
            const style = getComputedStyle(bleed);
            if (style.stroke !== 'rgb(17, 17, 17)' || style.strokeDasharray !== '1px, 4px') throw new Error('Bleed must be black and dotted');
          }
            }''')
        assert_paths()
        for width, height in [(1366, 900), (1101, 768), (800, 900), (620, 700), (540, 700), (390, 700), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            if width <= 1100:
                self.page.get_by_role('tab', name='Preview', exact=True).click()
            self.page.wait_for_timeout(80)
            expect(self.page.get_by_text('Preview options', exact=True)).to_have_count(0)
            geometry = toolbar.evaluate('''e => {
              const r = e.getBoundingClientRect(), previous = e.querySelector('.previous').getBoundingClientRect(), next = e.querySelector('.next').getBoundingClientRect();
              return {x:r.x, y:r.y, width:r.width, height:r.height,
                rightAligned:Math.abs(e.querySelector('.elm-presets-menu').getBoundingClientRect().right - (r.left + Math.max(e.clientWidth,e.scrollWidth) - e.scrollLeft - parseFloat(getComputedStyle(e).paddingRight))) < 2,
                oneRow:[...e.querySelectorAll('#impose-presets-trigger, .artwork-fitting .da-radio-group__options, .preview-side-controls button, .sheet-nav-status, .sheet-nav-button')].every(control => Math.abs(control.getBoundingClientRect().top + control.getBoundingClientRect().height/2 - (previous.top+previous.height/2)) < 2),
                adjacent:Math.abs(previous.top - next.top) < 1 && previous.right <= next.left};
            }''')
            assert geometry['rightAligned'] and geometry['adjacent'] and geometry['oneRow'], (width, height, geometry)
            assert_paths()
            before = toolbar.bounding_box()
            self.button('Next sheet').click()
            self.idle()
            expect(self.page.locator('.sheet-nav-status')).to_contain_text('Sheet 2 of')
            expect(self.button('Previous sheet')).to_be_enabled()
            assert_paths()
            self.button('Previous sheet').click()
            self.idle()
            expect(self.page.locator('.sheet-nav-status')).to_contain_text('Sheet 1 of')
            expect(self.button('Previous sheet')).to_be_disabled()
            assert_paths()
            after = toolbar.bounding_box()
            assert all(abs(after[key] - before[key]) < 1 for key in before), (width, height, 'Sheet navigation moves the toolbar')
            for name in ['Zoom in', 'Zoom out', 'Fit sheet', 'Hide setup toolbar', 'Show setup toolbar']:
                expect(self.button(name)).to_have_count(0)
            style = self.page.locator('.piece-cut-path').first.evaluate('e => { const s=getComputedStyle(e); return {width:s.strokeWidth, vector:s.vectorEffect, dash:s.strokeDasharray, color:s.stroke}; }')
            assert style == {'width':'1.5px', 'vector':'non-scaling-stroke', 'dash':'6px, 4px', 'color':'rgb(214, 40, 40)'}, style
            assert_paths()
            self.page.screenshot(path=str(self.out/f'preview-toolbar-{width}x{height}.png'))
        # The side toggle adds another toolbar control; keep setup usable on
        # narrow screens as well as checking simplex navigation above.
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.fresh()
        self.impose([a_pdf, b_pdf])
        self.step('Sheet')
        self.dropdown('Printing', 'double')
        self.idle()
        for width, height in [(1366, 900), (390, 700), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            if width <= 1100:
                self.page.get_by_role('tab', name='Setup', exact=True).click()
            self.button('Show back').click()
            self.idle()
            expect(self.button('Show front')).to_be_visible()
            assert_paths()
            self.button('Show front').click()
            self.idle()
            assert_paths()
            assert self.page.locator('.gang-setup-fields').bounding_box()['height'] > 60, (width, height, 'Duplex toolbar collapses setup')
            self.page.screenshot(path=str(self.out/f'preview-duplex-toolbar-{width}x{height}.png'))
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('preview toolbar: always-visible cut paths without guide toggles or cut lines, stable single-row navigation, complete paths across sheets/duplex, presets at far right, no zoom or collapse controls at desktop/tablet/mobile/breakpoints')

    def preset_toolbar(self):
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.fresh()
        self.impose(stripe)
        self.step('Sheet')
        self.button('Repeat pages').click()
        self.close_quantities()
        self.page.get_by_label('Copies', exact=True).fill('61')
        self.idle()
        menu = self.page.locator('.elm-presets-menu')
        trigger = self.page.get_by_role('button', name='Presets', exact=True)
        trigger.focus()
        trigger.press('Space')
        expect(menu.locator('.da-popover')).to_be_visible()
        self.page.keyboard.press('Escape')
        expect(menu.locator('.da-popover')).to_be_hidden()
        presets = []
        workflows = [
            ('21 business cards', 3.5, 2, 7, 3, 'Size'),
            ('4 5x7', 5, 7, 2, 2, 'Sheet'),
            ('2 Letter', 8.5, 11, 2, 1, 'Sheet'),
            ('4 4x6', 4, 6, 2, 2, 'Bleed'),
        ]
        for label, width, height, rows, columns, save_step in workflows:
            self.step('Size')
            self.button('Max per sheet').click()
            self.page.locator('#finished-width').fill(str(width))
            self.page.locator('#finished-height').fill(str(height))
            # Custom grid seeds its rotation from the current automatic layout.
            self.idle()
            self.button('Custom grid').click()
            self.page.get_by_label('Rows', exact=True).fill(str(rows))
            self.page.get_by_label('Columns', exact=True).fill(str(columns))
            self.idle()
            expected = self.layouts[-1]
            assert expected['piecesPerSheet'] == rows * columns, (label, expected)
            self.step(save_step)
            self.presets()
            name = f'{label} {self.name} {time.time_ns()}'
            self.page.get_by_label('Setup name', exact=True).fill(name)
            self.button('Save as new preset').click()
            option = self.preset_option(name)
            expect(option).to_have_count(1)
            presets.append((name, expected, save_step))
            self.close_presets()
        # Load from every production step and retain the artwork/copy count.
        self.fresh()
        self.impose(stripe)
        self.step('Sheet')
        self.button('Repeat pages').click()
        self.close_quantities()
        self.page.get_by_label('Copies', exact=True).fill('61')
        for preset_id, expected, load_step in presets:
            self.step(load_step)
            self.presets()
            self.dropdown('Apply preset', preset_id)
            self.idle()
            actual = self.layouts[-1]
            for key in ['finishedCutSize', 'parentSheetSize', 'rows', 'columns', 'piecesPerSheet', 'gutters', 'orientationPreference', 'bleed']:
                assert actual[key] == expected[key], (key, actual, expected)
            assert actual['impressionQuantities'] == [61]
            expect(self.page.locator('.setup-stepper [aria-selected=true]')).to_have_text(load_step)
            self.expect_file('stripes.png')
            self.close_presets()
        for width, height in [(1366, 560), (800, 900), (390, 700), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            if width <= 1100:
                self.page.get_by_role('tab', name='Preview', exact=True).click()
            self.presets()
            panel = menu.locator('.da-popover').bounding_box()
            assert panel['x'] >= 0 and panel['x'] + panel['width'] <= width + 1 and panel['y'] + panel['height'] <= height + 1, (width, height, panel)
            self.dropdown('Apply preset', presets[0][0])
            self.idle()
            assert self.layouts[-1]['piecesPerSheet'] == 21
            self.page.get_by_label('Setup name', exact=True).fill(f'Preview save {self.name} {width} {time.time_ns()}')
            self.button('Save as new preset').click()
            expect(self.page.locator('.toast')).to_contain_text('Saved work updated')
            self.page.screenshot(path=str(self.out/f'preset-toolbar-{width}x{height}.png'))
            self.close_presets()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('presets: save/load from all steps and Preview, persistent common grids on 12x18, retained artwork/copies, viewport-bounded menu at desktop/tablet/mobile')

    def fitting(self):
        self.fresh()
        self.impose(stripe)
        width = self.page.locator('#finished-width')
        width.fill('')
        width.press_sequentially('8.5', delay=40)
        expect(width).to_have_value('8.5')
        self.page.locator('#finished-height').fill('11')
        self.continue_to('Bleed')
        for mode in ['Fit', 'Fill', 'Stretch']:
            self.set_fitting(mode)
            self.idle()
            path = self.download('Download imposed PDF', f'imposed-{mode}.pdf')
            layout = self.layouts[-1]
            with fitz.open(path) as document:
                assert len(document) == layout['sheetsRequired']
                assert abs(document[0].rect.width - 864) < .1 and abs(document[0].rect.height - 1296) < .1
                pix = document[0].get_pixmap()
                cut = layout['placements'][0]
                x = (cut['finishedX'] + cut['finishedWidth'] / 2) * 72
                y = (cut['finishedY'] + cut['finishedHeight'] / 2) * 72
                color = pix.pixel(round(x), round(y))
                assert color[1] > 240 and color[0] < 20 and color[2] < 20, (mode, color)
                assert layout['finishedCutSize'] == {'width': 8.5, 'height': 11}
            expect(self.page.locator('.elm-crop-editor')).to_have_count(0)
        self.button('Scale to add bleed').click()
        self.page.get_by_label('Extend per side (in)',exact=True).fill('0.125')
        self.idle()
        path = self.download('Download imposed PDF', 'created-bleed.pdf')
        with fitz.open(path) as document:
            assert len(document) == self.layouts[-1]['sheetsRequired']
        self.checks.append('imposition fitting: direct Fit/Fill/Stretch exports retain chosen dimensions and centered artwork; created bleed; no crop UI')


    def mixed_and_saved(self):
        self.fresh()
        self.impose(six)
        assert all(size <= 4 for size in self.batch_sizes) and 4 in self.batch_sizes
        assert len(self.layouts[-1]['pagePlans']) == 6
        self.continue_to('Sheet')
        self.button('Repeat pages').click()
        expect(self.page.locator('#workspace-dialog')).to_be_visible()
        self.page.locator('#bulk-copy-quantity').fill('-1')
        expect(self.button('Apply to all')).to_be_disabled()
        self.page.locator('#bulk-copy-quantity').fill('0')
        self.button('Apply to all').press('Enter')
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)
        expect(self.button('Continue')).to_be_enabled()
        self.button('Edit copy quantities').click()
        self.page.locator('#bulk-copy-quantity').fill('2')
        self.button('Apply to all').click()
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2]*6
        self.button('Edit copy quantities').click()
        self.page.get_by_label('Page 2 copies',exact=True).fill('0')
        self.close_quantities()
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        self.dropdown('Printing', 'double')
        self.idle()
        assert len(self.layouts[-1]['impressionQuantities']) == 3
        self.dropdown('Printing', 'single')
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        self.set_fitting('Stretch')
        self.idle()
        self.continue_to('Bleed')
        path=self.download('Download imposed PDF','mixed-repeat.pdf')
        layout=self.layouts[-1]
        with fitz.open(path) as doc:
            assert len(doc)==layout['sheetsRequired']
            content=''.join(p.get_text() for p in doc)
            assert 'ART-1' in content and 'ART-3' in content and 'ART-2' not in content, content
        self.step('Size')
        self.presets()
        name=f'Elm {self.name} acceptance {time.time_ns()}'
        self.page.get_by_label('Setup name',exact=True).fill(name)
        self.button('Save preset').click()
        expect(self.preset_option(name)).to_have_count(1)
        preset_id=name
        self.button('Save recent job').click()
        if self.page.get_by_text('Recent jobs',exact=True).locator('..').get_attribute('open') is None:
            self.page.get_by_text('Recent jobs',exact=True).click()
        expect(self.page.locator('.elm-saved li').filter(has_text=name)).to_have_count(2)
        self.page.locator('#finished-width').fill('bad')
        expect(self.button('Continue')).to_be_enabled()
        self.presets()
        manage = self.page.locator('.elm-saved details').filter(has=self.page.get_by_text('Manage presets', exact=True))
        if manage.get_attribute('open') is None:
            manage.locator('summary').click()
        manage.locator('li').filter(has_text=preset_id).get_by_role('button', name='Apply', exact=True).click()
        expect(self.page.locator('#finished-width')).to_have_value('3')
        self.idle()
        assert self.layouts[-1]['impressionQuantities']==[2,0,2,2,2,2]
        self.expect_file('mixed.pdf')
        self.page.get_by_label('Setup name',exact=True).fill(name+' renamed')
        self.button('Update preset').click()
        expect(self.preset_option(name+' renamed')).to_have_count(1)
        self.page.get_by_label('Setup name',exact=True).fill(name+' renamed again')
        self.button('Rename').click()
        expect(self.preset_option(name+' renamed again')).to_have_count(1)
        expect(self.page.get_by_text('Export history',exact=True)).to_have_count(0)
        assert self.context.request.get(args.url+'/gang-up/export-history').status == 404
        recent=self.page.locator('.elm-saved details').filter(has=self.page.get_by_text('Recent jobs',exact=True))
        row=recent.locator('li').filter(has_text=name)
        row.get_by_role('button',name='Restore setup',exact=True).click()
        self.idle()
        self.close_presets()
        self.step('Sheet')
        self.dropdown('Printing', 'double')
        self.idle()
        self.step('Sheet')
        self.page.get_by_text('Advanced sheet settings',exact=True).click()
        self.dropdown('Duplex flip edge', 'shortEdge')
        self.page.get_by_label('Rotate back side 180°',exact=True).check()
        self.idle()
        self.step('Bleed')
        path=self.download('Download imposed PDF','duplex.pdf')
        layout=self.layouts[-1]
        with fitz.open(path) as doc:
            assert len(doc)==2*layout['sheetsRequired']
            assert 'ART-1' in doc[0].get_text() and 'ART-2' in doc[1].get_text()
        self.step('Size')
        self.button('Custom grid').click()
        self.page.get_by_label('Rows',exact=True).fill('2')
        self.page.get_by_label('Columns',exact=True).fill('2')
        self.idle()
        assert self.layouts[-1]['rows']==2 and self.layouts[-1]['columns']==2
        self.step('Sheet')
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
        self.presets()
        if manage.get_attribute('open') is None:
            manage.locator('summary').click()
        self.page.locator('.elm-saved li').filter(has_text=name+' renamed again').get_by_role('button',name='Delete',exact=True).click()
        expect(self.preset_option(name)).to_have_count(0)
        if self.page.get_by_text('Recent jobs',exact=True).locator('..').get_attribute('open') is None:
            self.page.get_by_text('Recent jobs',exact=True).click()
        self.page.locator('.elm-saved li').filter(has_text=name).get_by_role('button',name='Delete',exact=True).click()
        expect(self.page.locator('.elm-saved li').filter(has_text=name)).to_have_count(0)
        self.checks.append('mixed/saved: four-page batch bound, mixed geometry and shared fitting, zero/bulk/individual copies, simplex/duplex drafts + exported fronts/backs, manual grid/margins, preset CRUD/repair/retention, recent restore/delete, no export history controls or endpoint')

    def impression_selection(self):
        self.fresh()
        food = pathlib.Path(__file__).resolve().parents[1] / 'pdf_examples' / 'before' / 'resize_food_menu.pdf'
        self.impose(food)
        self.page.locator('#finished-width').fill('8.5')
        self.page.locator('#finished-height').fill('11')
        self.step('Sheet')
        self.button('Repeat pages').click()
        self.close_quantities()
        self.page.get_by_label('Copies',exact=True).fill('2')
        self.idle()
        first = self.page.locator('#sheet-item-0')
        second = self.page.locator('#sheet-item-1')
        selection = self.page.locator('.piece-selection')
        expect(selection).to_have_count(0)
        second.locator('.piece-hit-area').click()
        expect(second).to_have_attribute('data-selected','true')
        expect(first).to_have_attribute('data-selected','false')
        expect(selection).to_have_attribute('data-impression-index','1')
        first.focus()
        expect(first).to_have_attribute('data-selected','true')
        expect(second).to_have_attribute('data-selected','false')
        expect(selection).to_have_attribute('data-impression-index','0')
        second.locator('.piece-hit-area').click(button='right')
        menu = self.page.locator('#artwork-context-menu')
        expect(menu).to_be_visible()
        expect(selection).to_have_count(1)
        expect(selection).to_have_attribute('data-impression-index','1')
        self.page.screenshot(path=str(self.out/'impression-selection-menu.png'))
        menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).press('Escape')
        expect(second).to_be_focused()
        style = selection.evaluate('''e => {
          const item = document.querySelector('.sheet-item[data-selected=true]');
          const hit = item.querySelector('.piece-hit-area'), style = getComputedStyle(e);
          for (const key of ['x','y','width','height']) if (hit.getAttribute(key) !== e.getAttribute(key)) throw new Error('Selection does not match selected cut');
          return {outline:getComputedStyle(item).outlineStyle, stroke:style.strokeWidth, effect:style.vectorEffect, color:style.stroke, dash:style.strokeDasharray};
        }''')
        selection_colors = {
            'dark': ('rgb(237, 237, 237)', 'rgb(23, 23, 23)'),
            'light': ('rgb(0, 127, 148)', 'rgb(255, 255, 255)'),
        }
        selection_color, halo_color = selection_colors[self.page.locator('html').get_attribute('data-theme')]
        assert style == {'outline':'none','stroke':'2.5px','effect':'non-scaling-stroke','color':selection_color,'dash':'none'}, style
        halo = self.page.locator('.piece-selection-halo')
        assert halo.evaluate('e => getComputedStyle(e).stroke') == halo_color
        expect(selection).to_have_count(1)
        expect(self.page.locator('.piece-selection-halo')).to_have_count(1)
        assert self.page.locator('.sheet-item[data-selected=true]').count() == 1
        self.page.screenshot(path=str(self.out/'impression-selection.png'))
        self.toggle_theme()
        second.focus()
        selection_color, halo_color = selection_colors[self.page.locator('html').get_attribute('data-theme')]
        expect(selection).to_have_css('stroke', selection_color)
        expect(halo).to_have_css('stroke', halo_color)
        self.page.screenshot(path=str(self.out/'impression-selection-light.png'))
        self.toggle_theme()
        self.checks.append('impression selection: one selected repeated copy, pointer/keyboard/open context menu and focus return, themed 2.5px outline with contrasting border in both themes, exact cut geometry, no native SVG focus ring, light/dark screenshots')



    def artwork_rotation(self):
        artwork = fitz.open()
        for width, height in [(216, 144), (144, 216)]:
            page = artwork.new_page(width=width, height=height)
            for x, y, color in [(0,0,(1,0,0)), (1,0,(0,1,0)), (0,1,(0,0,1)), (1,1,(1,1,0))]:
                page.draw_rect(fitz.Rect(x*width/2,y*height/2,(x+1)*width/2,(y+1)*height/2),color=None,fill=color)
        fixture = fixtures / 'rotation-quadrants.pdf'
        artwork.save(fixture)
        artwork.close()
        self.fresh()
        self.impose(fixture)
        self.set_fitting('Fill')
        self.idle()
        self.continue_to('Bleed')
        assert self.page.locator('.elm-preview-summary').count() == 0
        assert self.page.get_by_text('pieces per sheet',exact=False).count() == 0
        target = self.page.locator('.sheet-item[data-artwork-page="2"]')
        hit = target.locator('.piece-hit-area')
        menu = self.page.locator('#artwork-context-menu')
        def open_menu():
            hit.click(button='right')
            expect(menu).to_be_visible()
            expect(menu).to_have_attribute('aria-label','Page 2 artwork actions')
        open_menu()
        expect(menu.get_by_role('menuitem',name='Reset rotation',exact=True)).to_be_disabled()
        menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).press('ArrowDown')
        expect(menu.get_by_role('menuitem',name='Rotate counterclockwise 90°',exact=True)).to_be_focused()
        menu.get_by_role('menuitem',name='Rotate counterclockwise 90°',exact=True).press('Escape')
        expect(menu).to_be_hidden()
        expect(target).to_be_focused()
        target.press('Shift+F10')
        expect(menu).to_be_visible()
        menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).click()
        self.idle()
        layout = self.layouts[-1]
        assert [plan['rotationDegrees'] for plan in layout['pagePlans']] == [0,90]
        assert all(plan['finishedCutSize']=={'width':3,'height':2} for plan in layout['pagePlans'])
        # Independently sample screen and PDF quadrants, including asymmetric
        # rotation direction, source fitting, and an unchanged neighboring page.
        colors = {'red':(255,0,0),'green':(0,255,0),'blue':(0,0,255),'yellow':(255,255,0)}
        expected = {0:['red','green','blue','yellow'],90:['blue','red','yellow','green'],180:['yellow','blue','green','red'],270:['green','yellow','red','blue']}
        for rotation in [90,180,270,0]:
            if rotation != 90:
                open_menu()
                menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).click()
                self.idle()
            layout = self.layouts[-1]
            assert [p['rotationDegrees'] for p in layout['pagePlans']] == [0,rotation]
            path = self.download('Download imposed PDF',f'artwork-rotation-{rotation}.pdf')
            screen = Image.open(io.BytesIO(self.page.screenshot())).convert('RGB')
            with fitz.open(path) as document:
                sheet = document[0]
                pix = sheet.get_pixmap(matrix=fitz.Matrix(1,1),alpha=False)
                raster = Image.frombytes('RGB',(pix.width,pix.height),pix.samples)
                for index in [0,1]:
                    bounds = self.page.locator(f'.sheet-item[data-artwork-page="{index+1}"] .piece-hit-area').bounding_box()
                    placement = layout['placements'][index]
                    names = expected[((rotation if index == 1 else 0) + layout['rotationDegrees']) % 360]
                    for (x,y),name in zip([(0.25,0.25),(0.75,0.25),(0.25,0.75),(0.75,0.75)],names):
                        pdf_pixel = raster.getpixel((round((placement['finishedX']+x*placement['finishedWidth'])*72),round((placement['finishedY']+y*placement['finishedHeight'])*72)))
                        screen_pixel = screen.getpixel((round(bounds['x']+bounds['width']*x),round(bounds['y']+bounds['height']*y)))
                        assert max(abs(a-b) for a,b in zip(pdf_pixel,colors[name]))<12,(rotation,index,pdf_pixel,name)
                        assert max(abs(a-b) for a,b in zip(screen_pixel,colors[name]))<25,(rotation,index,screen_pixel,name)
        open_menu()
        menu.get_by_role('menuitem',name='Rotate 180°',exact=True).click()
        self.idle()
        open_menu()
        menu.get_by_role('menuitem',name='Reset rotation',exact=True).click()
        self.idle()
        assert self.layouts[-1]['pagePlans'][1]['rotationDegrees'] == 0
        open_menu()
        menu.get_by_role('menuitem', name='Rotate counterclockwise 90°', exact=True).click()
        self.idle()
        assert self.layouts[-1]['pagePlans'][1]['rotationDegrees'] == 270
        for width,height in [(1366,768),(800,900),(390,700)]:
            self.page.set_viewport_size({'width':width,'height':height})
            if width <= 1100:
                self.page.get_by_role('tab',name='Preview',exact=True).click()
            target.scroll_into_view_if_needed()
            target.focus()
            target.press('Enter')
            expect(menu).to_be_visible()
            bounds = menu.bounding_box()
            assert bounds['x']>=0 and bounds['y']>=0 and bounds['x']+bounds['width']<=width and bounds['y']+bounds['height']<=height,bounds
            menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).press('Escape')
            expect(target).to_be_focused()
            hit.click(button='right')
            expect(menu).to_be_visible()
            self.page.locator('.sheet-paper').click(position={'x':2,'y':2})
            expect(menu).to_be_hidden()
        self.page.set_viewport_size({'width':1366,'height':900})
        # The shop's real portrait and landscape originals share one 8.5x11
        # finished cut and the existing two-up 12x18 sheet after page rotation.
        examples = pathlib.Path(__file__).resolve().parents[1] / 'pdf_examples' / 'before'
        food = examples / 'resize_food_menu.pdf'
        wine = examples / 'resize_wine_menu.pdf'
        self.fresh()
        self.impose([food,wine])
        self.page.locator('#finished-width').fill('8.5')
        self.page.locator('#finished-height').fill('11')
        self.idle()
        hit = self.page.locator('.sheet-item[data-artwork-page="2"] .piece-hit-area')
        open_menu()
        menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).click()
        self.idle()
        layout = self.layouts[-1]
        assert layout['piecesPerSheet'] == 2 and layout['sheetsRequired'] == 1
        assert layout['rotationDegrees'] == 90
        assert [p['rotationDegrees'] for p in layout['pagePlans']] == [0,90]
        assert all(abs(p['artwork']['width']-8.75)<0.001 and abs(p['artwork']['height']-11.25)<0.001 for p in layout['pagePlans'])
        self.continue_to('Bleed')
        path = self.download('Download imposed PDF','mixed-food-wine.pdf')
        with fitz.open(path) as result:
            assert len(result) == 1
            actual = [word[4] for word in result[0].get_text('words')]
            wanted = []
            for original in [food,wine]:
                with fitz.open(original) as source:
                    wanted.extend(word[4] for word in source[0].get_text('words'))
            assert sorted(actual) == sorted(wanted), (len(actual),len(wanted))
        open_menu()
        self.page.screenshot(path=str(self.out/'mixed-artwork-context-menu.png'))
        menu.get_by_role('menuitem',name='Rotate clockwise 90°',exact=True).press('Escape')
        self.presets()
        self.page.get_by_label('Setup name',exact=True).fill('Rotation '+self.name)
        with self.page.expect_response(lambda response: response.url.endswith('/gang-up/recent-jobs') and response.request.method == 'POST'):
            self.button('Save recent job').click()
        saved = self.context.request.get(args.url+'/gang-up/recent-jobs').json()
        assert saved[0]['request']['pageOverrides'][0]['rotationDegrees'] == 90
        self.context.request.delete(args.url+'/gang-up/recent-jobs/'+saved[0]['id'])
        self.close_presets()
        self.step('Size')
        self.step('Sheet')
        self.button('Repeat pages').click()
        expect(self.page.locator('#workspace-dialog')).to_be_visible()
        self.page.locator('#bulk-copy-quantity').fill('2')
        self.button('Apply to all').click()
        self.idle()
        layout = self.layouts[-1]
        assert layout['impressionQuantities'] == [2,2] and layout['sheetsRequired'] == 2
        self.continue_to('Bleed')
        repeated = self.download('Download imposed PDF','mixed-food-wine-repeated.pdf')
        with fitz.open(repeated) as result:
            assert len(result) == 2
            actual = [word[4] for page in result for word in page.get_text('words')]
            assert sorted(actual) == sorted(wanted*2)
        self.checks.append('artwork rotation: independent mixed orientations, 0/90/180/270 screen/PDF quadrant parity, reset, keyboard menu/focus, outside dismissal, bounded desktop/tablet/mobile menu, no canvas count strip')

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
        self.page.locator('.bleed-status').click()
        self.page.get_by_label('PDF bleed per side (in)',exact=True).fill('0.125')
        self.button('Use auto-detected bleed').wait_for()
        self.wait_pending(pending)
        current=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        assert current==old_url, 'Displayed preview changed while its replacement was pending'
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/gang-up/sources/*/previews')
        self.idle()
        self.button('Use auto-detected bleed').click()
        self.idle()
        attempts=[]
        def fail_preview(route):
            attempts.append(route.request.post_data_json)
            route.fulfill(status=503,body='Controlled preview failure')
        self.page.route('**/gang-up/sources/*/previews',fail_preview)
        self.page.locator('.bleed-status').click()  # Change identity to an uncached amount below.
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
        self.expect_file('bleed.pdf')
        self.select(three)
        self.idle()
        self.expect_file('three.pdf')
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
        self.wait_pending(pending)
        self.button('Cancel').click()
        for route,response in pending: route.fulfill(response=response)
        self.page.unroute('**/gang-up/sources')
        self.page.wait_for_timeout(500)
        self.expect_file('three.pdf')
        self.checks.append('preview/replacement: retained raster during delayed replacement, bounded automatic retries + explicit recovery, manual-bleed cache identity, corrupt replacement, source deletion, cancelled preparation late response')

    def lifecycle(self):
        self.fresh()
        self.impose(three)
        old_url=self.page.locator('.sheet-svg image').first.get_attribute('href') or self.page.locator('.sheet-svg image').first.get_attribute('xlink:href')
        source=self.source_ids[-1]
        self.button('Clear').click()
        self.button('Keep working').click()
        expect(self.page.locator('#workspace-dialog')).to_have_count(0)
        self.idle()
        self.expect_file('three.pdf')
        pending=[]
        self.page.route('**/gang-up/layout',lambda route:pending.append((route,route.fetch())))
        self.page.locator('#finished-width').fill('4.25')
        self.wait_pending(pending)
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
        expect(self.page.locator('#finished-width')).to_have_value('3')
        expect(self.page.locator('#finished-height')).to_have_value('2')
        expect(self.button('Continue')).to_be_enabled()
        self.checks.append('lifecycle: clear confirmation/cancel, late layout after clear rejected, source deletion and URL revocation, new upload initializes original finished dimensions')

    def workspace_animation(self):
        self.fresh()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.select(stripe)
        self.idle()
        self.page.get_by_role('combobox', name='Tool', exact=True).click()
        samples = self.page.get_by_role('option', name='Impose artwork', exact=True).evaluate('''button => new Promise(resolve => {
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
        # Shrinking used to measure the header after changing its grid alignment,
        # animate to an intrinsic width, then snap back when animation ended.
        self.fresh()
        self.select(three)
        for width, height in [(1366, 900), (1366, 768), (800, 900)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            for target in ['PDF to images', 'Extract pages']:
                self.switch('Impose artwork')
                self.idle()
                self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
                self.page.get_by_role('combobox', name='Tool', exact=True).click()
                frames = self.page.get_by_role('option', name=target, exact=True).evaluate('''button => new Promise(resolve => {
                  const bounds = selector => {
                    const element = document.querySelector(selector);
                    if (!element) return null;
                    const r = element.getBoundingClientRect();
                    return {x:r.x, y:r.y, width:r.width, height:r.height};
                  };
                  const snapshot = () => ({header:bounds('.app-header'), card:bounds('.ready-card'), action:bounds('.submit-row')});
                  const frames = [snapshot()], start = performance.now();
                  button.click();
                  const sample = now => {
                    frames.push(snapshot());
                    if (now - start < 800) requestAnimationFrame(sample);
                    else resolve(frames);
                  };
                  requestAnimationFrame(sample);
                })''')
                (self.out/f'return-{target.replace(" ", "-")}-{width}x{height}.json').write_text(json.dumps(frames, indent=2))
                for part in ['header', 'card', 'action']:
                    measured = [frame[part] for frame in frames if frame[part] is not None]
                    assert measured, (part, frames)
                    first, last = measured[0], measured[-1]
                    for key in ['x', 'y', 'width', 'height']:
                        low, high = sorted([first[key], last[key]])
                        assert all(low - 1 <= frame[key] <= high + 1 for frame in measured), (part, key, frames)
                    # The final animation frames and removal must converge;
                    # no late correction is allowed after reaching the target.
                    assert all(abs(frame[key] - last[key]) < 1 for frame in measured[-10:] for key in last), (part, frames[-10:])
                assert abs(frames[-1]['header']['width'] - frames[-1]['card']['width']) < 1
                assert abs(frames[-1]['card']['x'] - (width - frames[-1]['card']['width']) / 2) < 1
            # Reverse while expanding; the departed workspace must stay gone.
            self.switch('Impose artwork')
            self.page.wait_for_timeout(100)
            self.switch('PDF to images')
            self.idle()
            self.page.wait_for_function("!document.querySelector('.elm-shell').hasAttribute('data-workspace-animating')")
            assert self.page.locator('.ready-card.imposing').count() == 0
            expect(self.button('Download images')).to_be_visible()
        self.page.set_viewport_size({'width': 1366, 'height': 900})
        self.checks.append('workspace animation: monotonic expansion and PDF-to-images/extraction return, header/card/action bounds without overshoot or late snap at desktop/laptop/half-screen sizes, rapid reversal, reduced-motion bypass')

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
            trigger = self.button('Workspace')
            bounds = trigger.bounding_box()
            assert bounds['width'] >= 80 and abs(bounds['height'] - 44) < 0.5, (width, height, bounds)
            assert trigger.evaluate('e => { const r = e.getBoundingClientRect(); return e.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)); }'), (width, height, 'Workspace trigger is clipped')
            if width<=1100:
                self.page.get_by_role('tab',name='Setup',exact=True).click()
            action=self.button('Continue')
            action.scroll_into_view_if_needed()
            box=action.bounding_box()
            assert box and box['x']>=-1 and box['y']>=-1 and box['x']+box['width']<=width+1 and box['y']+box['height']<=height+1,(width,height,box)
            assert self.page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1'),(width,height)
            assert self.page.evaluate('''() => {
              const button=document.querySelector('.setup-continue-button');
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
            self.set_fitting('Fill')
            self.idle()
            control = self.page.get_by_role('group', name='Artwork fitting', exact=True)
            control.scroll_into_view_if_needed()
            bounds = control.bounding_box()
            assert bounds['x'] >= 0 and bounds['x'] + bounds['width'] <= width + 1, (width, height, bounds)
            self.page.screenshot(path=str(self.out/f'artwork-fitting-{width}x{height}{suffix}.png'))
            self.set_fitting('Fit')
            self.idle()
            if width<=1100:
                self.page.get_by_role('tab',name='Preview',exact=True).click()
            sheet=self.page.locator('.sheet-svg')
            expect(sheet).to_be_visible()
            box=sheet.bounding_box()
            assert box['width']>80 and box['height']>80,(width,height,box)
            self.page.screenshot(path=str(self.out/f'impose-{width}x{height}{suffix}.png'))
        self.toggle_theme()
        expect(self.page.locator('html')).to_have_attribute('data-theme', 'light')
        for width, height in [(1366, 900), (320, 568)]:
            self.page.set_viewport_size({'width': width, 'height': height})
            self.page.wait_for_timeout(80)
            if width <= 1100:
                self.page.get_by_role('tab', name='Preview', exact=True).click()
            expect(self.page.locator('.sheet-svg')).to_be_visible()
            self.page.screenshot(path=str(self.out/f'impose-light-{width}x{height}.png'))
        self.toggle_theme()
        self.page.set_viewport_size({'width':390,'height':700})
        self.switch('Images to PDF')
        expect(self.button('Create PDF')).to_be_visible()
        self.button('Create PDF').scroll_into_view_if_needed()
        assert self.page.evaluate('document.documentElement.scrollWidth <= innerWidth + 1')
        self.page.screenshot(path=str(self.out/'images-narrow.png'))
        self.checks.append('responsive: desktop/short/tablet/narrow, 1100/1101 + 880/881 + 539/540 boundaries, 320px reachability/hit testing, preview bounds, no page overflow')

    def startup(self):
        for suffix in ['app.css','elm.js','bootstrap.js','bridge.js','da-components.js']:
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
        # Loaded code can still lack Elm.Main or the required bridge ports.
        # Both bootstrap failures must reach the same Retry interface.
        for body in ['window.Elm = {};', 'window.Elm = {Main: {init: () => ({ports: {}})}};']:
            self.page.route('**/elm.js', lambda route: route.fulfill(status=200, content_type='text/javascript', body=body))
            self.page.goto(args.url)
            expect(self.page.locator('#startup-retry')).to_be_visible()
            self.page.unroute('**/elm.js')
            self.page.locator('#startup-retry').click()
            expect(self.button('Browse files')).to_be_visible()
        self.checks.append('startup: CSS, Elm, JavaScript bootstrap, and resource bridge failure + retry; missing Elm module/ports recovery')

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
