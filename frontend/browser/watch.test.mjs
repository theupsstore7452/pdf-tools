import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

test('development watcher survives repeated atomic saves without watching generated output', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pdf-tools-watcher-'));
  let child;
  try {
    for (const dir of ['elm', 'browser', 'assets', 'node_modules/da-components', 'dist']) {
      await fs.mkdir(path.join(root, dir), { recursive: true });
    }
    await fs.copyFile(new URL('../watch.mjs', import.meta.url), path.join(root, 'watch.mjs'));
    await fs.writeFile(path.join(root, 'build.mjs'), "import fs from 'node:fs'; fs.appendFileSync('builds.log', 'built\\n');\n");
    await fs.writeFile(path.join(root, 'styles.css'), 'initial');
    child = spawn(process.execPath, [path.join(root, 'watch.mjs')], { stdio: ['ignore', 'ignore', 'pipe'] });
    let errors = '';
    child.stderr.on('data', data => { errors += data; });
    await sleep(200);
    const count = async () => {
      try { return (await fs.readFile(path.join(root, 'builds.log'), 'utf8')).trim().split('\n').length; }
      catch { return 0; }
    };
    const atomicSave = async (file, expected) => {
      await fs.writeFile(path.join(root, file + '.tmp'), String(expected));
      await fs.rename(path.join(root, file + '.tmp'), path.join(root, file));
      for (let i = 0; i < 100 && await count() < expected; i++) await sleep(30);
      assert.equal(await count(), expected, errors);
    };
    await atomicSave('styles.css', 1);
    await atomicSave('styles.css', 2);
    await atomicSave('elm/Main.elm', 3);
    await atomicSave('elm/Main.elm', 4);
    await fs.writeFile(path.join(root, 'dist/app.html'), 'generated');
    await sleep(350);
    assert.equal(await count(), 4, 'generated output must not create a build loop');
    assert.equal(errors, '');
  } finally {
    if (child && child.exitCode === null) {
      const exit = once(child, 'exit');
      child.kill();
      await exit;
    }
    await fs.rm(root, { recursive: true, force: true });
  }
});
