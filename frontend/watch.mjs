import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
process.chdir(path.dirname(fileURLToPath(import.meta.url)));
let timer, building = false, pending = false;
function build() {
 if (building) { pending = true; return; }
 building = true;
 const child = spawn(process.execPath,['build.mjs'],{stdio:'inherit'});
 child.on('exit',() => { building = false; if (pending) { pending = false; build(); } });
}
// Watch parent directories: atomic saves replace a file's inode and otherwise
// silently detach fs.watch(file). Keep generated dist output outside the allowlist.
const rootFiles = new Set(['styles.css','bridge.js','elm.json','build.mjs']);
for (const target of ['.','elm','browser','assets','node_modules/da-components']) {
 fs.watch(target,{recursive:['elm','browser','node_modules/da-components'].includes(target)},(_event, filename) => {
  if (!filename) return;
  const name = String(filename);
  if (name.split(path.sep).some(part => ['_build','.git'].includes(part))) return;
  if (target === '.' && !rootFiles.has(name)) return;
  if (target === 'assets' && name !== 'elm.html') return;
  clearTimeout(timer); timer = setTimeout(build,150);
 });
}
