import fs from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
process.chdir(path.dirname(new URL(import.meta.url).pathname));
let timer, building = false, pending = false;
function build() {
 if (building) { pending = true; return; }
 building = true;
 const child = spawn(process.execPath,['build.mjs'],{stdio:'inherit'});
 child.on('exit',() => { building = false; if (pending) { pending = false; build(); } });
}
for (const target of ['elm','styles.css','bridge.js','assets/elm.html']) {
 fs.watch(target,{recursive:target==='elm'},() => { clearTimeout(timer); timer = setTimeout(build,150); });
}
