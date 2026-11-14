#!/usr/bin/env python3
"""Exercise task discovery, output summaries and responsive preview inspection.

Run against a disposable local server, never production:
  python scripts/interface-browser-regressions.py --url http://127.0.0.1:3001
Requires the project's Nix Python/Playwright environment.
"""
import argparse
import pathlib
import fitz
from PIL import Image
from playwright.sync_api import sync_playwright, expect

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:3001')
parser.add_argument('--output', default='/tmp/pdf-tools-interface-review')
parser.add_argument('--browsers', default='chromium,firefox')
args = parser.parse_args()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=True)
fixture = root / 'five-pages.pdf'
doc = fitz.open()
for number in range(1, 6):
    page = doc.new_page(width=216, height=144)
    page.insert_text((18, 50), f'PAGE {number}', fontsize=20)
doc.save(fixture)
doc.close()
second = root / 'second.pdf'
doc = fitz.open()
doc.new_page(width=216, height=144)
doc.save(second)
doc.close()
image = root / 'sample.png'
Image.new('RGB', (300, 600), 'white').save(image)


def upload(page, files, label='Browse files'):
    with page.expect_file_chooser() as chooser:
        page.get_by_role('button', name=label, exact=True).click()
    chooser.value.set_files([str(file) for file in files])


def choose(page, name):
    page.locator('.home-tool-choice').filter(has=page.locator('.home-tool-name', has_text=name)).click()


def download(page, button, path):
    with page.expect_download() as result:
        page.get_by_role('button', name=button, exact=True).click()
    result.value.save_as(path)
    assert path.stat().st_size > 0
    return result.value.suggested_filename


def idle(page):
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    expect(page.locator('[data-layout-state=pending]')).to_have_count(0, timeout=60000)
    expect(page.locator('.preview-cache-status').filter(has_text='Updating preview')).to_have_count(0, timeout=60000)
    expect(page.get_by_role('button', name='Cancel', exact=True)).to_have_count(0, timeout=60000)


def step(page, name):
    tab = page.locator('.setup-stepper').get_by_role('tab', name=name, exact=True)
    tab.click()
    page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
    expect(tab).to_have_attribute('aria-selected', 'true')
    expect(tab).to_be_focused()


def open_options(page, selector, label):
    details = page.locator(selector)
    summary = details.locator('summary').first
    expect(summary).to_have_text(label)
    if details.get_attribute('open') is None:
        summary.click()
    expect(details).to_have_attribute('open', '')
    return details


def select_option(page, name, value):
    page.get_by_role('combobox', name=name, exact=True).click()
    page.get_by_role('option', name=value, exact=True).click()
    idle(page)


with sync_playwright() as playwright:
    for engine in args.browsers.split(','):
        browser = getattr(playwright, engine).launch()
        context = browser.new_context(viewport={'width': 1440, 'height': 1000}, accept_downloads=True)
        page = context.new_page()
        page.set_default_timeout(20000)
        errors = []
        layouts = []
        inspection_requests = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('response', lambda response: layouts.append(response.json()) if response.url.endswith('/gang-up/layout') and response.ok else None)
        page.on('request', lambda request: inspection_requests.append(request.url) if request.method == 'POST' and (request.url.endswith('/gang-up/layout') or request.url.endswith('/previews')) else None)
        out = root / engine
        out.mkdir(exist_ok=True)
        page.goto(args.url)
        expect(page.locator('.home-tool-choice')).to_have_count(5)
        for width, height in [(320, 740), (390, 844), (768, 1024), (1440, 1000)]:
            page.set_viewport_size({'width': width, 'height': height})
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
            page.screenshot(path=str(out / f'home-{width}.png'), full_page=True)

        # Explicit tool intent survives intake; incompatible inputs remain recoverable.
        choice = page.locator('.home-tool-choice').filter(has=page.locator('.home-tool-name', has_text='Images to PDF'))
        choice.focus()
        choice.press('Space')
        expect(page.get_by_role('button', name='Browse files', exact=True)).to_be_focused()
        upload(page, [fixture])
        expect(page.get_by_role('alert')).to_contain_text('Choose PNG or JPEG')
        expect(page.locator('.home-tools')).to_be_visible()
        choose(page, 'Extract pages')
        upload(page, [fixture])
        expect(page.get_by_role('combobox', name='Tool', exact=True)).to_have_text('Extract pages')
        expect(page.locator('.output-summary')).to_contain_text('5 single-page PDFs')
        page.get_by_role('button', name='Page range', exact=True).click()
        page.get_by_role('textbox', name='Pages', exact=True).fill('1-3, 5')
        page.get_by_role('button', name='Apply range', exact=True).click()
        page.get_by_role('radio', name='Page groups', exact=True).check()
        page.get_by_label('Pages per chunk', exact=True).fill('3')
        expect(page.locator('.output-summary')).to_contain_text('4 selected pages → 1 ZIP containing 2 PDFs')
        page.get_by_role('radio', name='One PDF', exact=True).check()
        output = out / 'extracted.pdf'
        assert download(page, 'Download PDF', output).endswith('.pdf')
        with fitz.open(output) as result:
            assert result.page_count == 4

        # Add files is visible next to the list and summaries follow the real output.
        upload(page, [second], 'Add files')
        expect(page.get_by_role('combobox', name='Tool', exact=True)).to_have_text('Combine PDFs')
        expect(page.locator('.output-summary')).to_contain_text('2 PDFs → 1 PDF · 6 pages')
        output = out / 'combined.pdf'
        download(page, 'Download PDF', output)
        with fitz.open(output) as result:
            assert result.page_count == 6

        page.goto(args.url)
        choose(page, 'Images to PDF')
        upload(page, [image])
        expect(page.locator('.output-summary')).to_contain_text('1 image → 1 PDF')
        output = out / 'image.pdf'
        download(page, 'Create PDF', output)
        with fitz.open(output) as result:
            assert result.page_count == 1

        page.goto(args.url)
        choose(page, 'PDF to images')
        upload(page, [second])
        expect(page.locator('.output-summary')).to_have_text('1 page → 1 PNG image · 144 DPI')
        output = out / 'page.png'
        assert download(page, 'Download images', output).endswith('.png')
        assert output.read_bytes().startswith(b'\x89PNG')

        # Imposition: visible step actions, bounded zoom and preview-only guide controls.
        page.goto(args.url)
        choose(page, 'Impose artwork')
        upload(page, [second])
        expect(page.locator('.sheet-svg')).to_be_visible()
        expect(page.get_by_role('button', name='Next: Sheet', exact=True)).to_be_visible()
        idle(page)
        expect(page.locator('.setup-stepper [role=tab]')).to_have_text(['Size', 'Sheet', 'Review'])
        size_options = page.locator('.size-layout-options')
        expect(size_options.locator('summary').first).to_have_text('Orientation and layout')
        expect(size_options).not_to_have_attribute('open', '')
        expect(size_options.get_by_role('combobox', name='Finished orientation', exact=True, include_hidden=True)).to_be_hidden()
        expect(size_options.get_by_role('radio', name='Custom grid', exact=True, include_hidden=True)).to_be_hidden()
        expect(page.locator('.sheet-nav-status')).to_have_text('1 print sheet')
        expect(page.get_by_role('button', name='Previous sheet', exact=True)).to_have_count(0)
        expect(page.get_by_role('button', name='Next sheet', exact=True)).to_have_count(0)
        page.get_by_role('button', name='Next: Sheet', exact=True).click()
        page.get_by_role('button', name='Next: Review', exact=True).click()
        expect(page.get_by_role('tabpanel', name='Review', exact=True)).to_be_visible()
        trim = page.locator('.trim-options')
        expect(trim.locator('summary').first).to_have_text('Trim and bleed options')
        expect(trim).not_to_have_attribute('open', '')
        expect(trim.locator('.setup-options-content')).to_be_hidden()
        expect(page.locator('.output-summary')).to_contain_text('1 PDF')
        expect(page.locator('.review-settings')).to_contain_text('Actual size (100%)')
        assert page.locator('.output-summary').evaluate("e => !!(e.compareDocumentPosition(document.querySelector('.trim-options')) & Node.DOCUMENT_POSITION_FOLLOWING)")
        step(page, 'Size')
        expect(page.locator('.size-layout-options')).not_to_have_attribute('open', '')
        for theme in ['light', 'dark']:
            if theme == 'dark':
                page.get_by_role('switch', name='Dark mode').click()
            for width, height in [(320, 740), (390, 844), (768, 1024), (1440, 1000), (844, 390)]:
                page.set_viewport_size({'width': width, 'height': height})
                if width <= 1100:
                    setup_tab = page.get_by_role('tab', name='Setup', exact=True)
                    preview_tab = page.get_by_role('tab', name='Preview', exact=True)
                    setup_tab.click()
                    setup_tab.press('ArrowRight')
                    expect(preview_tab).to_be_focused()
                    expect(preview_tab).to_have_attribute('aria-controls', 'gang-preview-panel')
                    preview_tab.press('Home')
                    expect(setup_tab).to_be_focused()
                    expect(setup_tab).to_have_attribute('aria-controls', 'gang-setup-panel')
                toolbar = page.locator('.elm-toolbar')
                assert toolbar.evaluate('e => e.scrollWidth <= e.clientWidth + 1')
                assert page.locator('.artwork-fitting label').evaluate_all('es => es.every(e => e.getBoundingClientRect().height <= 48)')
                expect(page.locator('.sheet-nav-status')).to_have_text('1 print sheet')
                expect(page.get_by_role('button', name='Previous sheet', exact=True)).to_have_count(0)
                expect(page.get_by_role('button', name='Next sheet', exact=True)).to_have_count(0)
                page.screenshot(path=str(out / f'setup-{theme}-{width}x{height}.png'))
                if width <= 1100:
                    page.get_by_role('tab', name='Preview', exact=True).click()
                guides = page.locator('.preview-guide-options')
                expect(guides.locator('summary').first).to_have_text('Guide options')
                expect(guides).not_to_have_attribute('open', '')
                expect(guides.locator('.preview-guide-controls')).to_be_hidden()
                expect(page.get_by_role('button', name='Zoom in', exact=True)).to_be_visible()
                idle(page)
                work = len(inspection_requests)
                page.get_by_role('button', name='Zoom in', exact=True).click()
                expect(page.locator('.preview-zoom-status')).to_have_text('150% of fit')
                viewport = page.locator('.preview-sheet-viewport')
                assert viewport.evaluate('e => e.clientHeight >= 200')
                assert viewport.evaluate('e => e.scrollWidth > e.clientWidth && e.scrollHeight > e.clientHeight')
                open_options(page, '.preview-guide-options', 'Guide options')
                expect(page.locator('.preview-guide-legend')).to_be_visible()
                cut_paths = page.locator('.piece-cut-path')
                cut_count = cut_paths.count()
                assert cut_count > 0
                page.get_by_role('button', name='Show guides', exact=True).click()
                expect(cut_paths).to_have_count(0)
                page.get_by_role('button', name='Show guides', exact=True).click()
                expect(cut_paths).to_have_count(cut_count)
                expect(cut_paths.first).to_have_css('stroke', 'rgb(214, 40, 40)')
                expect(cut_paths.first).to_have_css('vector-effect', 'non-scaling-stroke')
                guides.locator('summary').first.click()
                expect(guides).not_to_have_attribute('open', '')
                page.get_by_role('button', name='Fit to sheet', exact=True).click()
                expect(page.locator('.preview-zoom-status')).to_have_text('100% of fit')
                assert viewport.evaluate('e => e.scrollWidth <= e.clientWidth + 1')
                page.wait_for_timeout(250)
                assert len(inspection_requests) == work, 'Preview inspection triggered server work'
                if width <= 1100:
                    review_action = page.get_by_role('button', name='Review and download', exact=True)
                    expect(review_action).to_be_visible()
                    review_action.click()
                    expect(page.get_by_role('tab', name='Setup', exact=True)).to_have_attribute('aria-selected', 'true')
                    expect(page.get_by_role('tabpanel', name='Review', exact=True)).to_be_visible()
                    expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_enabled()
                    page.get_by_role('tab', name='Preview', exact=True).click()
                page.screenshot(path=str(out / f'preview-{theme}-{width}x{height}.png'))
        page.set_viewport_size({'width': 1440, 'height': 1000})
        step(page, 'Size')
        page.locator('.toolbar-more > summary').click()
        expect(page.get_by_role('button', name='Organize pages', exact=True)).to_be_visible()
        page.get_by_role('button', name='Organize pages', exact=True).click()
        expect(page.locator('.page-organizer')).to_be_visible()
        page.get_by_role('button', name='Cancel page ordering').click()

        # Advanced size controls are editable; manual settings and invalid drafts
        # remain discoverable after leaving and returning to the step.
        step(page, 'Size')
        options = page.locator('.size-layout-options')
        options.locator('summary').first.focus()
        options.locator('summary').first.press('Enter')
        expect(options).to_have_attribute('open', '')
        select_option(page, 'Finished orientation', 'Portrait')
        page.get_by_role('radio', name='Custom grid', exact=True).check()
        page.get_by_label('Rows', exact=True).fill('1')
        page.get_by_label('Columns', exact=True).fill('2')
        idle(page)
        expected_cut = layouts[-1]['finishedCutSize']
        step(page, 'Sheet')
        step(page, 'Size')
        expect(options).to_have_attribute('open', '')
        expect(page.get_by_role('combobox', name='Finished orientation', exact=True)).to_have_text('Portrait')
        expect(page.get_by_label('Rows', exact=True)).to_have_value('1')
        expect(page.get_by_label('Columns', exact=True)).to_have_value('2')
        assert layouts[-1]['finishedCutSize'] == expected_cut
        page.get_by_label('Rows', exact=True).fill('0')
        expect(page.locator('#rows-error')).to_be_visible()
        step(page, 'Review')
        expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_disabled()
        page.get_by_role('button', name='Check piece size and layout', exact=True).click()
        expect(page.get_by_role('tab', name='Size', exact=True)).to_have_attribute('aria-selected', 'true')
        expect(options).to_have_attribute('open', '')
        expect(page.get_by_label('Rows', exact=True)).to_have_attribute('aria-invalid', 'true')
        expect(page.locator('#rows-error')).to_be_visible()
        page.get_by_label('Rows', exact=True).fill('1')
        page.locator('#finished-width').fill('bad')
        expect(page.locator('#finished-width-error')).to_be_visible()
        step(page, 'Review')
        expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_disabled()
        page.get_by_role('button', name='Check piece size and layout', exact=True).click()
        expect(page.locator('#finished-width')).to_have_value('bad')
        expect(page.locator('#finished-width-error')).to_be_visible()
        page.locator('#finished-width').fill(str(expected_cut['width']))
        idle(page)

        # Review keeps print warnings outside the collapsed trim controls.
        step(page, 'Review')
        trim = open_options(page, '.trim-options', 'Trim and bleed options')
        page.get_by_role('radio', name='Scale to add bleed', exact=True).check()
        page.get_by_label('Extend per side (in)', exact=True).fill('0.125')
        idle(page)
        warnings = page.locator('.production-notes')
        assert layouts[-1]['warnings'], 'Expected a real production warning when enlarging artwork for bleed'
        for warning in layouts[-1]['warnings']:
            expect(warnings).to_contain_text(warning['problem'])
        assert warnings.evaluate("e => !e.closest('.trim-options')")
        trim.locator('summary').first.click()
        expect(trim).not_to_have_attribute('open', '')
        expect(warnings).to_be_visible()
        expect(warnings.locator('p').first).to_be_visible()
        step(page, 'Size')
        step(page, 'Review')
        expect(trim).to_have_attribute('open', '')
        expect(page.get_by_label('Extend per side (in)', exact=True)).to_have_value('0.125')
        page.get_by_label('Extend per side (in)', exact=True).fill('-1')
        expect(page.locator('#created-bleed-error')).to_be_visible()
        expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_disabled()
        step(page, 'Sheet')
        step(page, 'Review')
        expect(trim).to_have_attribute('open', '')
        expect(page.get_by_label('Extend per side (in)', exact=True)).to_have_attribute('aria-invalid', 'true')
        expect(page.locator('#created-bleed-error')).to_be_visible()
        page.get_by_label('Extend per side (in)', exact=True).fill('0.125')
        expect(page.locator('.bleed-source-setting')).not_to_have_attribute('open', '')
        expect(page.locator('.bleed-status')).to_contain_text('No uniform bleed detected')
        page.locator('.bleed-status').click()
        page.get_by_label('PDF bleed per side (in)', exact=True).fill('0.125')
        page.get_by_role('radio', name='Keep fitted placement', exact=True).check()
        idle(page)
        step(page, 'Size')
        step(page, 'Review')
        expect(trim).to_have_attribute('open', '')
        expect(page.locator('.bleed-source-setting')).to_have_attribute('open', '')
        expect(page.get_by_label('PDF bleed per side (in)', exact=True)).to_have_value('0.125')
        expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_enabled()
        page.get_by_role('button', name='Use auto-detected bleed', exact=True).click()
        idle(page)
        step(page, 'Size')
        step(page, 'Review')
        expect(trim).not_to_have_attribute('open', '')

        # More than one print sheet restores reachable navigation on every size.
        step(page, 'Sheet')
        page.get_by_role('radio', name='Repeat pages', exact=True).check()
        expect(page.locator('#workspace-dialog')).to_be_visible()
        page.get_by_role('button', name='Done', exact=True).click()
        idle(page)
        with page.expect_response(lambda response: response.url.endswith('/gang-up/layout') and response.request.post_data_json.get('quantityRequested') == 61) as changed_layout:
            page.get_by_label('Copies', exact=True).fill('61')
        idle(page)
        expect(page.locator('[data-layout-state]')).to_have_attribute('data-layout-state', 'ready')
        assert changed_layout.value.ok, changed_layout.value.text()
        assert changed_layout.value.json()['sheetsRequired'] > 1, changed_layout.value.json()
        for width, height in [(320, 740), (390, 844), (768, 1024), (1440, 1000), (844, 390)]:
            page.set_viewport_size({'width': width, 'height': height})
            if width <= 1100:
                page.get_by_role('tab', name='Preview', exact=True).click()
            next_sheet = page.get_by_role('button', name='Next sheet', exact=True)
            previous_sheet = page.get_by_role('button', name='Previous sheet', exact=True)
            expect(next_sheet).to_be_visible()
            expect(previous_sheet).to_be_disabled()
            for action in [next_sheet, previous_sheet]:
                assert action.evaluate('''e => {
                    const r=e.getBoundingClientRect();
                    return r.left >= 0 && r.right <= innerWidth + 1 && r.top >= 0 && r.bottom <= innerHeight + 1 && e.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));
                }'''), (engine, width, height, 'Sheet navigation is clipped or covered')
            next_sheet.click()
            idle(page)
            expect(page.locator('.sheet-nav-status')).to_contain_text('Sheet 2 of')
            expect(previous_sheet).to_be_enabled()
            previous_sheet.click()
            idle(page)
            expect(page.locator('.sheet-nav-status')).to_contain_text('Sheet 1 of')
            if width <= 1100:
                page.get_by_role('button', name='Review and download', exact=True).click()
                expect(page.get_by_role('tabpanel', name='Review', exact=True)).to_be_visible()
                expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_enabled()
        page.set_viewport_size({'width': 1440, 'height': 1000})
        step(page, 'Sheet')
        page.get_by_label('Copies', exact=True).fill('1')
        idle(page)
        step(page, 'Review')
        expect(page.locator('.sheet-nav-status')).to_have_text('1 print sheet')
        expect(page.get_by_role('button', name='Next sheet', exact=True)).to_have_count(0)
        expect(page.locator('.output-summary')).to_contain_text('1 PDF ·')
        expect(page.get_by_role('button', name='Download imposed PDF', exact=True)).to_be_enabled()
        output = out / 'imposed.pdf'
        download(page, 'Download imposed PDF', output)
        with fitz.open(output) as result:
            assert result.page_count >= 1
        assert not errors, errors
        context.close()

        if engine == 'chromium':
            # Synthesized touch proves scrolling the enlarged canvas, not just its layout.
            touch = browser.new_context(viewport={'width': 390, 'height': 844}, has_touch=True, is_mobile=True)
            p = touch.new_page()
            p.goto(args.url)
            choose(p, 'Impose artwork')
            upload(p, [fixture])
            p.get_by_role('tab', name='Preview', exact=True).click()
            expect(p.locator('.sheet-svg')).to_be_visible()
            p.get_by_role('button', name='Zoom in', exact=True).click()
            viewport = p.locator('.preview-sheet-viewport')
            box = viewport.bounding_box()
            cdp = touch.new_cdp_session(p)
            x, y = box['x'] + box['width'] * .75, box['y'] + box['height'] * .7
            cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': x, 'y': y}]})
            for n in range(1, 11):
                cdp.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': x - n * 10, 'y': y - n * 12}]})
                p.wait_for_timeout(20)
            cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
            p.wait_for_timeout(300)
            assert viewport.evaluate('e => e.scrollTop > 0 || e.scrollLeft > 0')
            p.get_by_role('button', name='Fit to sheet', exact=True).tap()
            expect(p.locator('.preview-zoom-status')).to_have_text('100% of fit')
            touch.close()
        browser.close()
        print(f'{engine}: PASS — task intent, intake recovery, summaries, five export workflows, collapsed defaults, retained advanced settings and invalid drafts, exposed print warnings, mobile Review action, one/multiple-sheet navigation, responsive layouts, local-only zoom and guide controls')
print('All interface regressions passed; Chromium synthesized-touch canvas scrolling passed.')
