#!/usr/bin/env python3
"""Real browser/output checks for shared page organization and oversized artwork.
Run inside the development shell with the app on port 3001. No workflow API is mocked.
"""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import struct
import time
import zipfile
import fitz
from PIL import Image
from playwright.sync_api import expect, sync_playwright

spec = importlib.util.spec_from_file_location('workflows', Path(__file__).with_name('workflow-regressions.py'))
workflows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflows)


def make_pdf(path, labels, size=(216,144)):
    document = fitz.open()
    for n, label in enumerate(labels,1):
        page = document.new_page(width=size[0],height=size[1])
        color = ((n % 5 + 1)/7, .75, .85)
        page.draw_rect(page.rect,color=None,fill=color)
        page.insert_text((18,72),label,fontsize=18)
    document.save(path)
    document.close()


def output_labels(path):
    with fitz.open(path) as pdf:
        return [page.get_text().strip() for page in pdf]


class PageChecks(workflows.Workflow):
    def __init__(self,*args):
        self.thumbnail_batches=[]
        super().__init__(*args)
        self.page.on('response',self.thumbnail_response)

    def thumbnail_response(self,response):
        if '/pdf/workspaces/' not in response.url or not response.url.endswith('/previews') or not response.ok:
            return
        body=response.body()
        assert body[:8]==b'PDFPV001'
        count=struct.unpack_from('>I',body,8)[0]
        assert 1<=count<=4
        at=12
        pages=[]
        for _ in range(count):
            page,length=struct.unpack_from('>II',body,at);at+=8
            with Image.open(io.BytesIO(body[at:at+length])) as image:
                assert image.width<=240 and image.height<=320,image.size
            pages.append(page);at+=length
        self.thumbnail_batches.append(pages)

    def organize(self):
        self.button('Organize pages').click()
        expect(self.page.get_by_role('heading',name='Organize pages',exact=True)).to_be_visible()
        expect(self.page.locator('.page-thumbnail img')).to_have_count(min(12,sum(max(1,x) for x in self.page_counts())),timeout=60000)
        expect(self.page.locator('.page-loading')).to_have_count(0,timeout=60000)

    def page_counts(self):
        # Fixture-driven methods use PDFs with known counts; the DOM count is
        # enough to verify that every visible item received a thumbnail.
        return [self.page.locator('#organized-pages .da-reorderable__item').count()]

    def actions(self):
        if self.page.locator('#page-order-actions').get_attribute('open') is None:
            self.page.locator('#page-order-actions > summary').click()

    def command(self,label):
        self.actions()
        self.button(label).click()

    def move(self,label,position):
        self.page.get_by_role('button',name='Select '+label,exact=True).click()
        self.actions()
        self.page.get_by_label('Move to position',exact=True).fill(str(position))
        self.button('Move page').click()

    def apply(self):
        self.button('Apply page order').click()
        self.idle()
        expect(self.page.locator('.page-organizer')).to_have_count(0)

    def extract(self,filename):
        self.button('Combined').click()
        return self.download('Download PDF',filename)

    def generic(self,source):
        self.select(source)
        self.organize()
        self.move('six-pages.pdf, page 3',1)
        self.page.locator('#organized-pages-item-4').focus()
        self.page.keyboard.press('Alt+ArrowUp')
        order=self.page.locator('#organized-pages .da-reorderable__item').evaluate_all('(items)=>items.map(i=>+i.id.split("-").at(-1))')
        assert order==[3,1,4,2,5,6],order
        self.page.locator('#organized-pages-item-6').drag_to(self.page.locator('#organized-pages-item-1'))
        order=self.page.locator('#organized-pages .da-reorderable__item').evaluate_all('(items)=>items.map(i=>+i.id.split("-").at(-1))')
        assert order==[3,6,1,4,2,5],order
        self.command('Restore original order')
        self.move('six-pages.pdf, page 3',1)
        self.apply()
        self.switch('Extract pages')
        self.range('1-3')
        result=self.extract('organized-extract.pdf')
        assert output_labels(result)==['PAGE 3','PAGE 1','PAGE 2']
        self.switch('PDF to images')
        result=self.download('Download images','organized-images.zip')
        with zipfile.ZipFile(result) as archive:
            names=sorted(archive.namelist())
            assert len(names)==6
            with Image.open(io.BytesIO(archive.read(names[0]))) as image:
                expected=(round(4/7*255),round(.75*255),round(.85*255))
                assert max(abs(a-b) for a,b in zip(image.convert('RGB').getpixel((10,10)),expected))<3
        self.organize()
        self.command('Reverse order')
        self.button('Cancel page ordering').click()
        self.organize()
        assert self.page.locator('#organized-pages .da-reorderable__item').first.get_attribute('id')=='organized-pages-item-3'
        self.page.locator('#page-order-actions').evaluate('(e)=>e.open=false')
        for theme in ['light','dark']:
            self.page.evaluate('(t)=>document.documentElement.dataset.theme=t',theme)
            for width,height in [(1366,900),(390,700),(320,568)]:
                self.page.set_viewport_size({'width':width,'height':height})
                self.page.screenshot(path=str(self.output/f'organizer-{theme}-{width}.png'))
                for label in ['Apply page order','Cancel page ordering']:
                    box=self.button(label).bounding_box()
                    assert box and box['x']>=0 and box['x']+box['width']<=width+1,(label,box,width)
                assert self.page.evaluate('document.documentElement.scrollWidth<=innerWidth+1')
                assert self.page.locator('.page-organizer-content').bounding_box()['height']>80
        self.button('Cancel page ordering').click()

    def combined(self,files):
        self.select(files)
        self.organize()
        self.move('second.pdf, page 1',1)
        self.apply()
        result=self.download('Download PDF','organized-combined.pdf')
        assert output_labels(result)==['B1','A1','A2','A3','B2','B3']

    def imposed(self,source):
        self.impose(source)
        self.organize()
        self.command('Reverse order')
        self.apply()
        self.step('Bleed')
        result=self.download('Download imposed PDF','organized-imposed.pdf')
        with fitz.open(result) as pdf:
            labels='\n'.join(p.get_text() for p in pdf)
            assert labels.index('PAGE 6')<labels.index('PAGE 5')<labels.index('PAGE 4')<labels.index('PAGE 1')
        # A failed replacement must not discard the committed page sequence.
        corrupt=self.output/'corrupt.png'
        corrupt.write_bytes(b'\x89PNG\r\n\x1a\nnot an image')
        self.select(corrupt)
        self.organize()
        assert self.page.locator('#organized-pages .da-reorderable__item').first.get_attribute('id')=='organized-pages-item-6'
        self.button('Cancel page ordering').click()
        self.idle()
        assert self.layouts[-1]['sourcePageCount']==6
        expect(self.button('Download imposed PDF')).to_be_enabled()
        # A second edit is relative to the already-ordered prepared source.
        self.organize()
        self.command('Restore original order')
        self.apply()
        result=self.download('Download imposed PDF','restored-imposed.pdf')
        with fitz.open(result) as pdf:
            labels='\n'.join(p.get_text() for p in pdf)
            assert labels.index('PAGE 1')<labels.index('PAGE 2')<labels.index('PAGE 6')

    def images(self,files):
        self.select(files)
        self.organize()
        self.command('Reverse order')
        self.apply()
        result=self.download('Create PDF','organized-image-inputs.pdf')
        with fitz.open(result) as pdf:
            assert len(pdf)==3
            for page,color in zip(pdf,[(0,0,255),(0,255,0),(255,0,0)]):
                pix=page.get_pixmap()
                assert max(abs(a-b) for a,b in zip(pix.pixel(10,10),color))<3

    def oversized(self,source):
        started=time.monotonic()
        self.impose(source)
        layout=self.layouts[-1]
        assert layout['finishedCutSize']=={'width':18.,'height':12.},layout
        assert layout['rotationDegrees']==90
        expect(self.page.locator('#finished-width')).to_have_value('18')
        expect(self.page.locator('#finished-height')).to_have_value('12')
        self.open_options('.size-layout-options', 'Orientation and layout')
        expect(self.page.get_by_role('combobox',name='Finished orientation',exact=True)).to_have_text('Landscape')
        expect(self.page.locator('.size-fit-notice')).to_contain_text('72 × 48')
        self.page.screenshot(path=str(self.output/'oversized-fit.png'))
        self.step('Sheet');self.dropdown('Print sheet size','8.5x11');self.idle()
        layout=self.layouts[-1]
        assert abs(layout['finishedCutSize']['width']-11)<.00001
        assert abs(layout['finishedCutSize']['height']-7.333333)<.00001
        self.dropdown('Print sheet size','13x19');self.idle()
        assert abs(self.layouts[-1]['finishedCutSize']['width']-19)<.00001
        self.dropdown('Print sheet size','8.5x11');self.idle()
        self.step('Bleed')
        result=self.download('Download imposed PDF','oversized-fitted.pdf')
        with fitz.open(result) as pdf:
            assert len(pdf)==1
            assert abs(pdf[0].rect.width-8.5*72)<.01 and abs(pdf[0].rect.height-11*72)<.01
            assert 'OVERSIZED ART' in pdf[0].get_text()
        self.metrics={'oversizedPrepareSeconds':round(time.monotonic()-started,3),'fittedSize':layout['finishedCutSize']}

    def pagination(self,source):
        self.select(source);self.organize()
        assert self.page.locator('#organized-pages .da-reorderable__item').count()==12
        assert sum(len(batch) for batch in self.thumbnail_batches)==12
        self.button('Next pages').click()
        expect(self.page.locator('.page-thumbnail img')).to_have_count(12,timeout=60000)
        expect(self.page.locator('.page-loading')).to_have_count(0)
        assert sum(len(batch) for batch in self.thumbnail_batches)==24
        self.command('Reverse order')
        expect(self.page.locator('.page-loading')).to_have_count(0,timeout=60000)
        assert self.page.locator('#organized-pages .da-reorderable__item').first.get_attribute('id')=='organized-pages-item-1000'
        assert self.page.locator('#organized-pages .da-reorderable__item').count()==12
        assert sum(len(batch) for batch in self.thumbnail_batches)==36
        self.page.screenshot(path=str(self.output/'thousand-page-document.png'))
        self.button('Cancel page ordering').click()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',default='http://127.0.0.1:3001')
    parser.add_argument('--output',default='/tmp/pdf-tools-organizer-review/regressions')
    args=parser.parse_args();root=Path(args.output);root.mkdir(parents=True,exist_ok=True)
    fixture=root/'fixtures';fixture.mkdir(exist_ok=True)
    make_pdf(fixture/'six-pages.pdf',[f'PAGE {n}' for n in range(1,7)])
    make_pdf(fixture/'first.pdf',['A1','A2','A3']);make_pdf(fixture/'second.pdf',['B1','B2','B3'])
    make_pdf(fixture/'oversized.pdf',['OVERSIZED ART'],(72*72,48*72))
    make_pdf(fixture/'thousand.pdf',[f'PAGE {n}' for n in range(1,1001)])
    images=[]
    for color in ['red','lime','blue']:
        path=fixture/(color+'.png');Image.new('RGB',(300,200),color).save(path);images.append(path)
    cases=[('generic',lambda w:w.generic(fixture/'six-pages.pdf')),('combine',lambda w:w.combined([fixture/'first.pdf',fixture/'second.pdf'])),('impose',lambda w:w.imposed(fixture/'six-pages.pdf')),('images',lambda w:w.images(images)),('oversized',lambda w:w.oversized(fixture/'oversized.pdf')),('pagination',lambda w:w.pagination(fixture/'thousand.pdf'))]
    results=[]
    with sync_playwright() as pw:
        browser=pw.chromium.launch(headless=True)
        for name,run in cases:
            print(name,flush=True)
            w=PageChecks(browser,args.url.rstrip('/'),root/name)
            record={'case':name}
            try:
                run(w);assert not w.errors,w.errors
                record.update(result='PASS',thumbnailBatches=w.thumbnail_batches,metrics=getattr(w,'metrics',{}))
            except Exception:
                w.page.screenshot(path=str(w.output/'failure.png'))
                record['result']='FAIL';raise
            finally:
                results.append(record);(root/'results.json').write_text(json.dumps(results,indent=2));w.close(failed=record['result']=='FAIL')
        browser.close()
    print('PASS: 6 page organization and oversized-artwork workflows',flush=True)

if __name__=='__main__':main()
