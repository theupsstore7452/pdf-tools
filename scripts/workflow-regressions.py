#!/usr/bin/env python3
"""Output-inspecting workflow regressions against a real PDF Tools server.

Requires Python Playwright, PyMuPDF, Pillow, Chromium and Firefox (included in
the Nix development shell). No workflow requests are mocked. Every case gets a
fresh browser context; failed cases retain a screenshot, DOM, and Playwright
trace. The JSON report includes every case and the process fails on any failure.
"""
import argparse
import io
import json
import math
import pathlib
import time
import traceback
import zipfile

import fitz
from PIL import Image, ImageChops, ImageStat
from playwright.sync_api import expect, sync_playwright


def make_fixtures(root):
    root.mkdir(parents=True, exist_ok=True)
    cuts = []
    for name, cut, bleed, boxes, rotation, unit in [
        ('trim-5x7', (5, 7), .125, 'trim', 0, 1),
        ('trim-landscape', (7, 5), .125, 'trim', 0, 1),
        ('trim-custom', (2.75, 3.75), .125, 'trim', 0, 1),
        ('trim-rotated-90', (5, 7), .125, 'trim', 90, 1),
        ('trim-rotated-270', (5, 7), .125, 'trim', 270, 1),
        ('trim-user-unit', (5, 7), .125, 'trim', 0, 2),
        ('bleed-box', (5, 7), .125, 'bleed', 0, 1),
        ('crop-only', (5, 7), .125, 'crop', 0, 1),
        ('crop-authoritative', (5.25, 7.25), .5, 'crop', 0, 1),
        ('untagged-5x7', (5, 7), .125, 'none', 0, 1),
        ('untagged-quarter-inch', (3.5, 2), .25, 'none', 0, 1),
        ('untagged-rotated', (5, 7), .125, 'none', 90, 1),
        ('explicit-full-trim', (5.25, 7.25), 0, 'trim', 0, 1),
        ('custom-no-bleed', (2.75, 3.75), 0, 'none', 0, 1),
    ]:
        doc = fitz.open()
        w, h = cut
        page = doc.new_page(width=(w + 2 * bleed) * 72 / unit,
                            height=(h + 2 * bleed) * 72 / unit)
        page.draw_rect(page.rect, color=None, fill=(0, 0, 1))
        rect = fitz.Rect(bleed * 72 / unit, bleed * 72 / unit,
                         (w + bleed) * 72 / unit, (h + bleed) * 72 / unit)
        page.draw_rect(rect, color=None, fill=(1, 0, 0))
        # A landmark with known physical width catches accidental scaling of
        # bleed-bearing artwork into the finished cut.
        page.draw_rect(fitz.Rect(rect.x0 + 36 / unit, rect.y0 + 36 / unit,
                                 rect.x0 + 72 / unit, rect.y0 + 72 / unit),
                       color=None, fill=(0, 1, 0))
        page.insert_text((rect.x0 + 18 / unit, rect.y0 + 110 / unit),
                         name, fontsize=10 / unit)
        if boxes in ('trim', 'bleed'):
            page.set_trimbox(rect)
        if boxes == 'bleed':
            page.set_bleedbox(page.rect)
        if boxes == 'crop':
            page.set_cropbox(rect)
        if unit != 1:
            doc.xref_set_key(page.xref, 'UserUnit', str(unit))
        page.set_rotation(rotation)
        path = root / (name + '.pdf')
        doc.save(path)
        doc.close()
        expected = cut[::-1] if rotation in (90, 270) else cut
        supplied_bleed = 0 if boxes == 'crop' and bleed not in (.0625, .125, .25) else bleed
        cuts.append((name, path, expected, supplied_bleed, rotation))

    pdfs = []
    for name, specs in [('first', [(216, 144, 0), (288, 216, 90)]),
                         ('second', [(360, 504, 0)]),
                         ('third', [(144, 216, 270)])]:
        doc = fitz.open()
        labels, sizes = [], []
        for i, (w, h, rotation) in enumerate(specs):
            page = doc.new_page(width=w, height=h)
            label = f'{name.upper()}-{i + 1}'
            page.insert_text((18, 50), label, fontsize=14)
            page.add_rect_annot(fitz.Rect(10, 10, 30, 30)).update()
            page.set_rotation(rotation)
            labels.append(label)
            sizes.append((h, w) if rotation else (w, h))
        path = root / f'{name}.pdf'
        doc.save(path)
        doc.close()
        pdfs.append((path, labels, sizes))

    images = []
    for name, mode, size, color, options in [
        ('opaque.png', 'RGB', (900, 600), 'red', {}),
        ('opaque.jpg', 'RGB', (600, 900), 'lime', {'quality': 98}),
        ('transparent.png', 'RGBA', (600, 300), (0, 0, 255, 128), {}),
        ('metadata-dpi.png', 'RGB', (1125, 675), 'red', {'dpi': (150, 150)}),
        ('card-sized.png', 'RGB', (1125, 675), 'blue', {}),
        ('card-sized.jpg', 'RGB', (1125, 675), 'blue', {'quality': 98}),
    ]:
        path = root / name
        Image.new(mode, size, color).save(path, **options)
        images.append((path, size, color))
    exif = Image.Exif()
    exif[274] = 6
    exif_path = root / 'exif-rotated.jpg'
    Image.new('RGB', (600, 300), 'yellow').save(exif_path, exif=exif, quality=98)
    images.append((exif_path, (300, 600), 'yellow'))
    return cuts, pdfs, images


class Workflow:
    def __init__(self, browser, url, output):
        self.url, self.output = url, output
        output.mkdir(parents=True, exist_ok=True)
        self.context = browser.new_context(accept_downloads=True,
                                          viewport={'width': 1366, 'height': 1000})
        self.context.tracing.start(screenshots=True, snapshots=True, sources=True)
        self.page = self.context.new_page()
        self.page.set_default_timeout(20000)
        self.errors, self.layouts, self.sources, self.analyses = [], [], [], []
        self.page.on('pageerror', lambda error: self.errors.append(str(error)))
        self.page.on('response', self.response)
        self.page.goto(url)
        expect(self.button('Browse files')).to_be_visible()

    def response(self, response):
        if response.ok and response.url.endswith('/gang-up/layout'):
            self.layouts.append(response.json())
        if response.ok and '/jobs/' in response.url and response.url.endswith('/download'):
            if 'application/json' in response.headers.get('content-type', ''):
                source = response.json()
                self.sources.append(source['sourceId'])
                self.analyses.append(source['analysis'])

    def button(self, name):
        return self.page.get_by_role('button', name=name, exact=True)

    def select(self, files):
        if isinstance(files, pathlib.Path):
            files = [files]
        name = 'Browse files' if self.button('Browse files').count() else (
            'Replace artwork' if self.button('Replace artwork').count() else 'Replace files')
        with self.page.expect_file_chooser() as chooser:
            self.button(name).click()
        chooser.value.set_files([str(path) for path in files])
        self.idle()

    def idle(self):
        self.page.evaluate('() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))')
        for name in ('Cancel', 'Cancel inspection'):
            expect(self.button(name)).to_have_count(0, timeout=60000)
        expect(self.page.locator('[data-layout-state=pending]')).to_have_count(0, timeout=60000)
        expect(self.page.locator('.preview-cache-status').filter(has_text='Updating preview')).to_have_count(0, timeout=60000)

    def impose(self, files):
        self.select(files)
        if not self.page.locator('#finished-width').count():
            self.button('Impose artwork').click()
        expect(self.page.locator('#finished-width')).to_be_visible(timeout=60000)
        self.idle()
        expect(self.page.locator('.sheet-svg')).to_be_visible()

    def step(self, name):
        self.page.get_by_role('tab', name=name, exact=True).click()
        self.idle()

    def download(self, name, filename):
        self.idle()
        expect(self.button(name)).to_be_enabled()
        with self.page.expect_download(timeout=60000) as event:
            self.button(name).click()
        assert event.value.failure() is None
        path = self.output / filename
        event.value.save_as(path)
        assert path.stat().st_size > 10
        self.idle()
        return path

    def range(self, value):
        self.button('Page range').click()
        self.page.locator('#range-input').fill(value)
        self.button('Apply range').click()

    def pdf_output(self, path, labels, sizes):
        with fitz.open(path) as doc:
            assert len(doc) == len(labels), (len(doc), labels)
            for page, label, size in zip(doc, labels, sizes):
                assert label in page.get_text(), (label, page.get_text())
                assert abs(page.rect.width - size[0]) < .1
                assert abs(page.rect.height - size[1]) < .1

    def cut(self, path, size, bleed, rotation):
        self.impose(path)
        expect(self.page.locator('#finished-width')).to_have_value(str(size[0]).removesuffix('.0'))
        expect(self.page.locator('#finished-height')).to_have_value(str(size[1]).removesuffix('.0'))
        self.step('Arrangement')
        self.page.get_by_text('Advanced sheet settings', exact=True).click()
        self.page.locator('#gang-setup-panel').get_by_label('Impression orientation', exact=True).select_option('upright')
        self.idle()
        layout = self.layouts[-1]
        assert layout['finishedCutSize'] == dict(zip(('width', 'height'), size)), layout
        plan = layout['pagePlans'][0]
        assert abs(plan['bleedAmount'] - bleed) < .001, plan
        self.step('Bleed')
        output = self.download('Download imposed PDF', 'imposed.pdf')
        slot = layout['placements'][0]
        cut = {
            'finishedX': slot['finishedX'] + (slot['finishedWidth'] - size[0]) / 2,
            'finishedY': slot['finishedY'] + (slot['finishedHeight'] - size[1]) / 2,
            'finishedWidth': size[0], 'finishedHeight': size[1],
        }
        svg = self.page.locator('.sheet-svg .piece-cut').first
        assert abs(float(svg.get_attribute('width')) - cut['finishedWidth']) < .001
        with fitz.open(output) as doc:
            assert len(doc) == layout['sheetsRequired']
            assert path.stem in doc[0].get_text()
            # Render twice the native point resolution to inspect cut and bleed.
            pix = doc[0].get_pixmap(matrix=fitz.Matrix(2, 2))
            def pixel(dx, dy):
                return pix.pixel(round((cut['finishedX'] + dx) * 144),
                                 round((cut['finishedY'] + dy) * 144))
            assert pixel(cut['finishedWidth'] / 2, cut['finishedHeight'] / 2)[0] > 240
            if bleed:
                for dx, dy in [(-bleed / 2, cut['finishedHeight'] / 2),
                               (cut['finishedWidth'] + bleed / 2, cut['finishedHeight'] / 2)]:
                    color = pixel(dx, dy)
                    assert color[2] > 240 and color[0] < 20, color
                # The green square stays half an inch wide after imposing.
                drawing = next(d for d in doc[0].get_drawings() if d['fill'] == (0, 1, 0))
                assert abs(drawing['rect'].width - 36) < .1, drawing
                assert abs(drawing['rect'].height - 36) < .1, drawing
        # Replacement refreshes automatic sizes; manual edits survive replacement.
        self.step('Size')
        self.page.locator('#finished-width').fill('2')
        self.page.locator('#finished-height').fill('3')
        self.select(path)
        expect(self.page.locator('#finished-width')).to_have_value('2')
        expect(self.page.locator('#finished-height')).to_have_value('3')

    def image_conversion(self, fixture):
        path, pixels, color = fixture
        self.select(path)
        output = self.download('Create PDF', 'converted.pdf')
        with fitz.open(output) as doc:
            assert len(doc) == 1
            assert abs(doc[0].rect.width - pixels[0] * 72 / 300) < .01
            assert abs(doc[0].rect.height - pixels[1] * 72 / 300) < .01
            actual = doc[0].get_pixmap().pixel(10, 10)
            expected = {'red': (255, 0, 0), 'lime': (0, 255, 0),
                        'blue': (0, 0, 255), 'yellow': (255, 255, 0)}.get(color) if isinstance(color, str) else (127, 127, 255)
            assert max(abs(a - b) for a, b in zip(actual, expected)) < 8, actual
        self.button('Impose artwork').click()
        self.idle()
        assert not self.analyses[-1]['likelyBleed']['detected'], self.analyses[-1]
        expect(self.page.locator('#finished-width')).to_have_value(str(pixels[0] / 300).removesuffix('.0'))
        expect(self.page.locator('#finished-height')).to_have_value(str(pixels[1] / 300).removesuffix('.0'))
        self.step('Bleed')
        imposed = self.download('Download imposed PDF', 'image-imposed.pdf')
        with fitz.open(imposed) as doc:
            cut = self.layouts[-1]['placements'][0]
            actual = doc[0].get_pixmap().pixel(round((cut['finishedX'] + .1) * 72),
                                              round((cut['finishedY'] + .1) * 72))
            assert max(abs(a - b) for a, b in zip(actual, expected)) < 8, actual

    def merge(self, fixtures):
        self.select([f[0] for f in fixtures])
        self.button('Combine PDFs').click()
        self.button('Move third.pdf up').click()
        self.idle()
        expect(self.page.locator('.file-meta > span')).to_have_text(['first.pdf', 'third.pdf', 'second.pdf'])
        self.button('Move third.pdf up').press('Enter')
        self.idle()
        expect(self.page.locator('.file-meta > span')).to_have_text(['third.pdf', 'first.pdf', 'second.pdf'])
        ordered = [fixtures[2], fixtures[0], fixtures[1]]
        path = self.download('Download PDF', 'merge.pdf')
        self.pdf_output(path, [l for f in ordered for l in f[1]], [s for f in ordered for s in f[2]])
        self.button('Remove first.pdf').click()
        path = self.download('Download PDF', 'merge-removed.pdf')
        self.pdf_output(path, ordered[0][1] + ordered[2][1], ordered[0][2] + ordered[2][2])

    def raster_and_extract(self, fixture):
        path, labels, sizes = fixture
        self.select(path)
        self.range('2,1,2')
        for format_name in ('PNG', 'JPEG'):
            self.button(format_name).click()
            for resolution, factor in [('Screen', 2), ('Standard', 300 / 72), ('High', 600 / 72)]:
                self.button(resolution).click()
                output = self.download('Download images', f'{format_name}-{resolution}.zip')
                with zipfile.ZipFile(output) as archive:
                    assert len(archive.namelist()) == 2
                    for entry, size in zip(archive.namelist(), sizes):
                        with Image.open(io.BytesIO(archive.read(entry))) as image:
                            assert image.format == format_name
                            assert abs(image.width - round(size[0] * factor)) <= 1
                            assert abs(image.height - round(size[1] * factor)) <= 1
        self.button('Extract pages').click()
        self.range('2')
        self.button('Combined').click()
        output = self.download('Download PDF', 'one-extracted.pdf')
        self.pdf_output(output, labels[1:], sizes[1:])
        self.button('All pages').click()
        self.button('Chunks').click()
        self.page.locator('#extract-chunk-size').fill('99')
        output = self.download('Download ZIP', 'oversized-chunk.zip')
        with zipfile.ZipFile(output) as archive:
            assert len(archive.namelist()) == 1
            chunk = self.output / 'chunk.pdf'
            chunk.write_bytes(archive.read(archive.namelist()[0]))
            self.pdf_output(chunk, labels, sizes)

    def image_order(self, fixtures):
        self.select([f[0] for f in fixtures[:3]])
        self.button('Move transparent.png up').click()
        self.idle()
        expect(self.page.locator('.file-meta > span')).to_have_text(['opaque.png', 'transparent.png', 'opaque.jpg'])
        self.button('Move transparent.png up').press('Enter')
        self.idle()
        expect(self.page.locator('.file-meta > span')).to_have_text(['transparent.png', 'opaque.png', 'opaque.jpg'])
        output = self.download('Create PDF', 'ordered-images.pdf')
        with fitz.open(output) as doc:
            assert len(doc) == 3
            expected = [fixtures[2], fixtures[0], fixtures[1]]
            for page, fixture in zip(doc, expected):
                assert abs(page.rect.width - fixture[1][0] * 72 / 300) < .01
                assert abs(page.rect.height - fixture[1][1] * 72 / 300) < .01
        self.button('Remove opaque.png').click()
        output = self.download('Create PDF', 'removed-image.pdf')
        with fitz.open(output) as doc:
            assert len(doc) == 2
            assert doc[0].get_pixmap().pixel(10, 10)[2] > 240
            assert doc[1].get_pixmap().pixel(10, 10)[1] > 240

    def repeat_grid(self, fixture, sheet):
        self.impose(fixture)
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.button('Repeat pages').click()
        self.step('Quantity & sheet')
        self.page.get_by_label('Copies', exact=True).fill('5')
        self.page.get_by_label('Print sheet size', exact=True).select_option(sheet)
        if sheet == 'custom':
            self.page.get_by_label('Sheet width (in)', exact=True).fill('10')
            self.page.get_by_label('Sheet height (in)', exact=True).fill('14')
        self.step('Arrangement')
        self.button('Custom grid').click()
        self.page.get_by_label('Rows', exact=True).fill('1')
        self.page.get_by_label('Columns', exact=True).fill('2')
        self.idle()
        layout = self.layouts[-1]
        assert layout['piecesPerSheet'] == 2 and layout['sheetsRequired'] == 3
        assert layout['impressionsRequested'] == 5
        expect(self.button('Previous sheet')).to_be_disabled()
        for _ in range(2):
            self.button('Next sheet').click()
            self.idle()
        expect(self.button('Next sheet')).to_be_disabled()
        expect(self.page.locator('.sheet-svg .piece-cut')).to_have_count(1)
        self.step('Bleed')
        output = self.download('Download imposed PDF', 'repeat-grid.pdf')
        with fitz.open(output) as doc:
            assert len(doc) == 3
            sheet_size = layout['parentSheetSize']
            assert abs(doc[0].rect.width - sheet_size['width'] * 72) < .1
            assert abs(doc[0].rect.height - sheet_size['height'] * 72) < .1
            if fixture.suffix == '.pdf':
                assert [p.get_text().count(fixture.stem) for p in doc] == [2, 2, 1]
            else:
                assert all(p.get_images() for p in doc)

    def duplex_setup(self, files, edge, rotate):
        self.impose(files)
        self.page.locator('#finished-width').fill('3')
        self.page.locator('#finished-height').fill('2')
        self.step('Quantity & sheet')
        self.page.get_by_label('Printing', exact=True).select_option('double')
        self.step('Arrangement')
        self.button('Custom grid').click()
        self.page.get_by_label('Rows', exact=True).fill('1')
        self.page.get_by_label('Columns', exact=True).fill('2')
        self.page.get_by_text('Advanced sheet settings', exact=True).click()
        self.page.locator('#gang-setup-panel').get_by_label('Impression orientation', exact=True).select_option('upright')
        self.page.get_by_label('Duplex flip edge', exact=True).select_option(edge)
        self.page.get_by_label('Rotate back side 180°', exact=True).set_checked(rotate)
        self.idle()
        self.step('Bleed')
        return self.download('Download imposed PDF', 'duplex.pdf')

    def duplex(self, fixtures, edge, rotate):
        output = self.duplex_setup([f[0] for f in fixtures], edge, rotate)
        layout = self.layouts[-1]
        sheet = layout['parentSheetSize']
        with fitz.open(output) as doc:
            assert len(doc) == 2
            # Two distinct pairs make back-side mirroring observable.
            labels = [l for f in fixtures for l in f[1]]
            for side, indices in enumerate(((0, 2), (1, 3))):
                page = doc[side]
                for slot_index, source_index in enumerate(indices):
                    label = labels[source_index]
                    assert label in page.get_text(), (label, page.get_text())
                    slot = layout['placements'][slot_index]
                    x = slot['finishedX'] + slot['finishedWidth'] / 2
                    y = slot['finishedY'] + slot['finishedHeight'] / 2
                    if side:
                        mirror_x = (edge == 'longEdge') != rotate
                        if mirror_x:
                            x = sheet['width'] - x
                        else:
                            y = sheet['height'] - y
                    rect = page.search_for(label)[0]
                    assert abs((rect.x0 + rect.x1) / 144 - x) < 1.5
                    assert abs((rect.y0 + rect.y1) / 144 - y) < 1
                    line = next(line for block in page.get_text('dict')['blocks'] if 'lines' in block
                                for line in block['lines'] if any(label in s['text'] for s in line['spans']))
                    source_rotation = (0, 90, 0, 270)[source_index]
                    angle = math.radians(source_rotation + (180 if side and rotate else 0))
                    assert abs(line['dir'][0] - math.cos(angle)) < .001, line
                    assert abs(line['dir'][1] - math.sin(angle)) < .001, line
        assert layout['duplex']['flipEdge'] == edge
        assert layout['duplex']['rotateBack180'] == rotate

    def duplex_images(self, fixtures, edge, rotate):
        output = self.duplex_setup([f[0] for f in fixtures[:4]], edge, rotate)
        layout = self.layouts[-1]
        sheet = layout['parentSheetSize']
        with fitz.open(output) as doc:
            assert len(doc) == 2
            for side, colors in enumerate((((255, 0, 0), (127, 127, 255)),
                                           ((0, 255, 0), (255, 0, 0)))):
                pix = doc[side].get_pixmap()
                for slot, color in zip(layout['placements'], colors):
                    x = slot['finishedX'] + slot['finishedWidth'] / 2
                    y = slot['finishedY'] + slot['finishedHeight'] / 2
                    if side:
                        if (edge == 'longEdge') != rotate:
                            x = sheet['width'] - x
                        else:
                            y = sheet['height'] - y
                    actual = pix.pixel(round(x * 72), round(y * 72))
                    assert max(abs(a - b) for a, b in zip(actual, color)) < 8, (side, actual, color)

    def image_recovery(self, fixture):
        corrupt = self.output / 'corrupt.png'
        corrupt.write_bytes(b'\x89PNG\r\n\x1a\nnot a readable image')
        self.select(corrupt)
        self.button('Create PDF').click()
        expect(self.page.get_by_role('alert')).to_be_visible(timeout=60000)
        self.idle()
        expect(self.button('Create PDF')).to_be_enabled()
        self.select(fixture[0])
        output = self.download('Create PDF', 'recovered.pdf')
        with fitz.open(output) as doc:
            assert len(doc) == 1
            assert doc[0].get_pixmap().pixel(10, 10)[0] > 240

    def reference_menu(self, source, reference, finished, rotation):
        self.impose(source)
        expect(self.page.locator('#finished-width')).to_have_value(str(finished[0]).removesuffix('.0'))
        expect(self.page.locator('#finished-height')).to_have_value(str(finished[1]).removesuffix('.0'))
        self.button('Repeat pages').click()
        self.step('Quantity & sheet')
        self.page.get_by_label('Copies', exact=True).fill('2')
        self.idle()
        self.step('Bleed')
        output = self.download('Download imposed PDF', 'menu-two-up.pdf')
        layout = self.layouts[-1]
        assert layout['parentSheetSize'] == {'width': 12, 'height': 18}
        assert layout['piecesPerSheet'] == 2 and layout['sheetsRequired'] == 1
        assert layout['impressionsRequested'] == 2 and layout['totalPiecesProduced'] == 2
        assert layout['rotationDegrees'] == rotation
        assert layout['pagePlans'][0]['finishedCutSize'] == dict(zip(('width', 'height'), finished))
        assert abs(layout['pagePlans'][0]['bleedAmount'] - .125) < .0001
        expect(self.page.locator('.sheet-svg .piece-cut')).to_have_count(2)
        for index, cut in enumerate(self.page.locator('.sheet-svg .piece-cut').all()):
            expected = {'x': .5, 'y': .3505 + index * 8.799, 'width': 11, 'height': 8.5}
            for key, value in expected.items():
                assert abs(float(cut.get_attribute(key)) - value) < .0001, (index, key, value)
        with fitz.open(reference) as expected, fitz.open(output) as actual:
            assert len(actual) == len(expected) == 1
            assert tuple(actual[0].rect) == tuple(expected[0].rect) == (0, 0, 864, 1296)
            wanted_words, actual_words = expected[0].get_text('words'), actual[0].get_text('words')
            assert len(actual_words) == len(wanted_words)
            for wanted, got in zip(wanted_words, actual_words):
                assert got[4] == wanted[4], (got, wanted)
                assert max(abs(a - b) for a, b in zip(got[:4], wanted[:4])) < .05, (got, wanted)
            wanted_pix, actual_pix = expected[0].get_pixmap(), actual[0].get_pixmap()
            wanted_image = Image.frombytes('RGB', (wanted_pix.width, wanted_pix.height), wanted_pix.samples)
            actual_image = Image.frombytes('RGB', (actual_pix.width, actual_pix.height), actual_pix.samples)
            difference = ImageChops.difference(wanted_image, actual_image)
            wanted_image.save(self.output / 'reference.png')
            actual_image.save(self.output / 'actual.png')
            difference.save(self.output / 'difference.png')
            mean_error = sum(ImageStat.Stat(difference).mean) / 3
            changed = difference.convert('L').point(lambda value: 255 if value > 32 else 0).histogram()[255]
            changed_fraction = changed / (wanted_pix.width * wanted_pix.height)
            metrics = {'meanChannelError': mean_error, 'changedPixelFraction': changed_fraction,
                       'maxChannelError': max(high for low, high in difference.getextrema()),
                       'textWordsCompared': len(wanted_words), 'reference': str(reference)}
            (self.output / 'comparison.json').write_text(json.dumps(metrics, indent=2))
            # Allow small color/rendering differences between PDF producers;
            # all text coordinates above still have a strict 0.05-point bound.
            assert mean_error < 2, metrics
            assert metrics['maxChannelError'] <= 32, metrics
            assert changed_fraction < .005, metrics

    def close(self, failed=False):
        if failed:
            self.page.screenshot(path=str(self.output / 'failure.png'), full_page=True)
            (self.output / 'failure-state.html').write_text(self.page.content())
        (self.output / 'layouts.json').write_text(json.dumps(self.layouts, indent=2))
        self.context.tracing.stop(path=str(self.output / 'trace.zip'))
        for source in self.sources:
            self.context.request.delete(self.url + '/gang-up/sources/' + source)
        self.context.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:3001')
    parser.add_argument('--browsers', default='chromium,firefox')
    parser.add_argument('--output', default='/tmp/pdf-elm-acceptance/workflows')
    parser.add_argument('--checks', default='cuts,images,merge,convert,order,grid,duplex,recovery,references')
    args = parser.parse_args()
    root = pathlib.Path(args.output)
    cuts, pdfs, images = make_fixtures(root / 'fixtures')
    cases = []
    for name, path, size, bleed, rotation in cuts:
        cases.append(('cuts', name, lambda w, p=path, s=size, b=bleed, r=rotation: w.cut(p, s, b, r)))
    for image in images:
        cases.append(('images', image[0].name, lambda w, f=image: w.image_conversion(f)))
    cases += [('merge', 'reorder-remove-rotations', lambda w: w.merge(pdfs)),
              ('convert', 'raster-extraction-matrix', lambda w: w.raster_and_extract(pdfs[0])),
              ('order', 'image-reorder-remove', lambda w: w.image_order(images)),
              ('recovery', 'corrupt-image-replacement', lambda w: w.image_recovery(images[0]))]
    for sheet in ('8.5x11', '11x17', '12x18', '13x19', 'custom'):
        for fixture in (cuts[0][1], images[0][0]):
            cases.append(('grid', sheet + '-' + fixture.suffix[1:],
                          lambda w, f=fixture, s=sheet: w.repeat_grid(f, s)))
    for edge in ('longEdge', 'shortEdge'):
        for rotate in (False, True):
            cases.append(('duplex', f'pdf-{edge}-rotate-{rotate}',
                          lambda w, e=edge, r=rotate: w.duplex(pdfs, e, r)))
            cases.append(('duplex', f'images-{edge}-rotate-{rotate}',
                          lambda w, e=edge, r=rotate: w.duplex_images(images, e, r)))
    examples = pathlib.Path(__file__).resolve().parent.parent / 'pdf_examples'
    for menu, finished, rotation in [('food', (8.5, 11), 90), ('wine', (11, 8.5), 0)]:
        source = examples / 'before' / f'resize_{menu}_menu.pdf'
        reference = examples / 'after' / f'resize_{menu}_menu-imp.pdf'
        if not source.is_file() or not reference.is_file():
            parser.error(f'Missing reference pair: {source}, {reference}')
        cases.append(('references', menu + '-letter-two-up',
                      lambda w, s=source, r=reference, f=finished, a=rotation: w.reference_menu(s, r, f, a)))
    selected = args.checks.split(',')
    unknown = set(selected) - {c[0] for c in cases}
    if unknown:
        parser.error(f'Unknown checks: {sorted(unknown)}')
    results = []
    with sync_playwright() as pw:
        for name in args.browsers.split(','):
            browser = getattr(pw, name).launch(headless=True)
            try:
                for group, case, run in cases:
                    if group not in selected:
                        continue
                    started = time.monotonic()
                    record = {'browser': name, 'version': browser.version, 'group': group, 'case': case}
                    workflow = None
                    print(f'{name}: {group}/{case}', flush=True)
                    try:
                        workflow = Workflow(browser, args.url.rstrip('/'), root / name / group / case)
                        run(workflow)
                        assert not workflow.errors, workflow.errors
                        record['status'] = 'passed'
                    except Exception:
                        record['status'] = 'failed'
                        record['error'] = traceback.format_exc()
                        print(record['error'], flush=True)
                    finally:
                        if workflow:
                            workflow.close(failed=record['status'] == 'failed')
                        record['seconds'] = round(time.monotonic() - started, 2)
                        results.append(record)
                        (root / 'results.json').write_text(json.dumps(results, indent=2))
            finally:
                browser.close()
    failed = sum(r['status'] == 'failed' for r in results)
    print(f'Workflow regressions: {len(results) - failed}/{len(results)} passed; reports: {root}', flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
