#!/usr/bin/env node
// Run inside nix develop .#pdf-app against the development server.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const session = `workspace-motion-${process.pid}`;
const output = resolve(process.argv[2] || '/tmp/pdf-tools-workspace-motion');
mkdirSync(output, { recursive: true });
const browser = (...args) => {
  const result = JSON.parse(execFileSync('agent-browser', ['--session', session, '--json', ...args], { encoding: 'utf8' }));
  assert.equal(result.success, true, JSON.stringify(result));
  return result.data;
};
const evaluate = code => browser('eval', code).result;
const idle = () => evaluate(`new Promise((resolve, reject) => {
  const start = performance.now();
  const poll = () => {
    if (performance.now() - start > 15000) return reject(new Error('Workspace did not settle'));
    if (document.querySelector('.toast-progress') || document.querySelector('.elm-impose-busy') || document.querySelector('[data-workspace-animating]')) return requestAnimationFrame(poll);
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  };
  poll();
})`);

function upload(paths) {
  browser('open', 'http://127.0.0.1:3200');
  browser('wait', '#upload-card');
  evaluate(`const input = document.createElement('input');
    input.type = 'file'; input.multiple = true; input.id = 'motion-files'; input.hidden = true;
    input.onchange = () => document.querySelector('.elm-shell').dispatchEvent(new CustomEvent('elm-files', {detail:Array.from(input.files), bubbles:true}));
    document.body.append(input);`);
  browser('upload', '#motion-files', ...paths);
  browser('wait', '[role="combobox"]');
  idle();
}

function transition(target, reduced = false) {
  const source = evaluate(`document.querySelector('[role="combobox"]').textContent.trim()`);
  browser('click', '[role="combobox"]');
  const frames = evaluate(`new Promise(resolve => {
    const box = selector => {
      const element = document.querySelector(selector);
      if (!element) return null;
      const r = element.getBoundingClientRect();
      return {x:r.x, y:r.y, width:r.width, height:r.height};
    };
    const snapshot = () => ({header:box('.app-header'), card:box('.ready-card'), action:box('.submit-row'), fields:box('.tool-form-fields'), animating:!!document.querySelector('[data-workspace-animating]')});
    const frames = [snapshot()], start = performance.now();
    [...document.querySelectorAll('[role="option"]')].find(e => e.textContent.startsWith(${JSON.stringify(target)})).click();
    const sample = now => {
      frames.push(snapshot());
      if (now - start < 650) requestAnimationFrame(sample);
      else resolve(frames);
    };
    requestAnimationFrame(sample);
  })`);
  idle();
  const name = `${source.replaceAll(' ', '-')}-to-${target.replaceAll(' ', '-')}-${evaluate('innerWidth + "x" + innerHeight')}-${reduced ? 'reduced' : 'motion'}`;
  writeFileSync(resolve(output, `${name}.json`), JSON.stringify(frames, null, 2));
  assert.equal(frames.at(-1).animating, false, name);
  if (reduced) assert.ok(frames.every(frame => !frame.animating), name);
  else assert.ok(frames.some(frame => frame.animating), `${name}: missing animation`);
  for (const part of ['header', 'card']) {
    for (const key of ['x', 'y', 'width', 'height']) {
      const first = frames[0][part][key], last = frames.at(-1)[part][key];
      assert.ok(frames.every(frame => frame[part][key] >= Math.min(first, last) - 1 && frame[part][key] <= Math.max(first, last) + 1), `${name}: ${part}.${key} overshoot`);
      assert.ok(frames.slice(-6).every(frame => Math.abs(frame[part][key] - last) < 1), `${name}: ${part}.${key} late jump`);
    }
  }
  if (frames.every(frame => frame.action)) {
    const padding = frame => frame.card.y + frame.card.height - frame.action.y - frame.action.height;
    assert.ok(frames.every(frame => Math.abs(padding(frame) - padding(frames.at(-1))) < 1), `${name}: action detached from card`);
    assert.ok(frames.every(frame => frame.fields.y + frame.fields.height <= frame.action.y + 1), `${name}: settings overlap action`);
  }
  assert.ok(evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), `${name}: horizontal overflow`);
  console.log(`Passed ${name}`);
}

const pdf = resolve('pdf_examples/before/resize_food_menu.pdf');
const secondPdf = resolve('pdf_examples/before/resize_wine_menu.pdf');
const image = resolve(output, 'artwork.png');
writeFileSync(image, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=', 'base64'));

try {
  for (const [width, height] of [[800, 900], [390, 700], [320, 568], [1366, 900], [1366, 768], [1366, 560]]) {
    browser('set', 'viewport', String(width), String(height));
    upload([pdf]);
    transition('Extract pages');
    transition('PDF to images');
    transition('Impose artwork');
    transition('Extract pages');
    transition('Impose artwork');
    transition('PDF to images');
    // Reverse the generic height animation before it completes.
    browser('click', '[role="combobox"]');
    evaluate(`new Promise(resolve => {
      [...document.querySelectorAll('[role="option"]')].find(e=>e.textContent.startsWith('Extract pages')).click();
      setTimeout(() => {
        document.querySelector('[role="combobox"]').click();
        requestAnimationFrame(() => {
          [...document.querySelectorAll('[role="option"]')].find(e=>e.textContent.startsWith('PDF to images')).click();
          setTimeout(resolve, 400);
        });
      }, 70);
    })`);
    idle();
    assert.ok(evaluate(`document.querySelector('.tool-form').getAttribute('aria-label') === 'PDF to images settings'`));
    browser('screenshot', resolve(output, `stack-${width}.png`));
  }
  browser('set', 'viewport', '1366', '900');
  upload([pdf, secondPdf]);
  transition('PDF to images');
  transition('Combine PDFs');
  transition('Impose artwork');
  transition('Combine PDFs');
  upload([image]);
  transition('Impose artwork');
  transition('Images to PDF');
  browser('set', 'media', 'light', 'reduced-motion');
  transition('Impose artwork', true);
  transition('Images to PDF', true);
  upload([pdf]);
  transition('Extract pages', true);
  transition('PDF to images', true);
  console.log(`All workflow motion checks passed. Traces and screenshots: ${output}`);
} finally {
  browser('close');
}
