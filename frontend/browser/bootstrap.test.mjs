import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./bootstrap.js', import.meta.url), 'utf8').replace('export function start', 'function start');
const bridge = readFileSync(new URL('../bridge.js', import.meta.url), 'utf8')
  .replace("import { install } from './da-components.js';", '')
  .replace('export function connect', 'function connect');

function browser(theme = 'dark') {
  const initialized = [], connected = [], responses = [], writes = [];
  const node = {};
  let receive;
  const app = {ports: {
    resources: {subscribe: callback => { receive = callback; }},
    browserEvents: {send: response => responses.push(JSON.parse(JSON.stringify(response)))},
  }};
  const context = {
    document: {getElementById: () => node, documentElement: {dataset: {theme}}, addEventListener() {}},
    window: {addEventListener() {}},
    matchMedia: () => ({addEventListener() {}}),
    install() {},
    Elm: {Main: {init: options => { initialized.push(options); return app; }}},
    localStorage: {setItem: (key, value) => writes.push([key, value])},
  };
  runInNewContext(source, context);
  const start = (connect = app => connected.push(app)) => context.start(connect);
  const connect = () => { runInNewContext(bridge, context); context.connect(app); };
  const send = value => receive(value);
  return {context, node, app, initialized, connected, responses, writes, start, connect, send};
}

test('mounts Elm with a valid theme before connecting its resource adapter', () => {
  for (const [theme, expected] of [['light', 'light'], ['dark', 'dark'], ['invalid', 'dark'], [undefined, 'dark']]) {
    const b = browser(theme);
    b.start(app => {
      assert.equal(app, b.app);
      assert.equal(b.initialized[0].node, b.node);
      assert.equal(b.initialized[0].flags, expected);
    });
  }
});

test('resource adapter persists raw theme preferences compatible with previous releases', () => {
  const b = browser();
  b.connect();
  for (const value of ['light', 'dark']) b.send({action: 'theme', value});
  assert.deepEqual(b.writes, [['pdf-tools-theme', 'light'], ['pdf-tools-theme', 'dark']]);
  assert.equal(b.context.document.documentElement.dataset.theme, 'dark');
  assert.deepEqual(b.responses, []);
});

test('blocked storage reports feedback to Elm while keeping the selected theme active', () => {
  for (const blocked of ['getter', 'write']) {
    const b = browser();
    if (blocked === 'getter') Object.defineProperty(b.context, 'localStorage', {get() { throw new Error('Storage unavailable'); }});
    else b.context.localStorage.setItem = () => { throw new Error('Storage unavailable'); };
    b.connect();
    b.send({action: 'theme', value: 'light'});
    assert.equal(b.context.document.documentElement.dataset.theme, 'light');
    assert.deepEqual(b.responses, [{action: 'themeStorageError'}]);
    assert.deepEqual(b.writes, []);
  }
});

test('missing mount, Elm module, or required port throws for startup Retry', () => {
  const broken = [
    b => { b.context.document.getElementById = () => null; },
    b => { delete b.context.Elm; },
    b => { b.context.Elm.Main.init = () => null; },
    ...['resources', 'browserEvents'].map(name => b => { delete b.app.ports[name]; }),
  ];
  for (const breakIt of broken) {
    const b = browser();
    breakIt(b);
    assert.throws(() => b.start());
    assert.deepEqual(b.connected, []);
  }
});

test('resource adapter errors propagate to the startup Retry boundary', () => {
  const b = browser();
  assert.throws(() => b.start(() => { throw new Error('Resource adapter failed'); }), /Resource adapter failed/);
});
