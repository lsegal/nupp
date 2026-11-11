import {runNuppLuaJITApp} from '../../../../runtime/luajit/app-runtime.mjs';
import {createCompiler} from '../../../../runtime/luajit/host.mjs';
import {createDeadlines} from '../../../../editors/playground/src/compiler-deadline.js';
const output = document.querySelector('#result');
const terminal = document.querySelector('#terminal');
const bytes = async name => new Uint8Array(await (await fetch(name)).arrayBuffer());
// Compiles the playground examples under the playground worker's own
// deadlines, so a first compile that outgrows them fails here.
const deadlines = createDeadlines();
let compiler, name;
try {
  const started = performance.now();
  compiler = await createCompiler({manifestUrl: './guest-manifest.json', app: await bytes('./compiler.ljbc'), deadlineMs: deadlines.deadlineMs});
  const startupMs = performance.now() - started;
  const initialize = await bytes('./app-runtime.lua');
  const sources = await (await fetch('./application-sources.json')).json();
  const results = [];
  for (const [entry, source] of Object.entries(sources)) {
    name = entry;
    terminal.textContent = name;
    const compileStarted = performance.now();
    const compiled = await deadlines.request(compiler, {kind:'compile', source, filename:'playground.nupp', options:{strict:true, optimize:true}});
    const compileMs = performance.now() - compileStarted;
    if (!compiled.code || compiled.diagnostics.some(x => x.severity === 'error')) throw new Error(JSON.stringify(compiled));
    const result = await runNuppLuaJITApp({manifestUrl:'./guest-manifest.json', app:new TextEncoder().encode(compiled.code), initialize, managed:true,
      storageName:'nupp-luajit-integration', limits:{perRun:{deadlineMs:15000}}, onProgress: x => {if(x.log) terminal.textContent = name+'\n'+x.log;}});
    results.push({name, compileMs, ...result});
  }
  name = undefined;
  output.textContent = JSON.stringify({ok:true, startupMs, results}); output.dataset.status='passed';
} catch(error) {
  // WebKit's `stack` leaves out the message, so report both.
  const message = (name ? name + ': ' : '') + String(error);
  output.textContent = JSON.stringify({ok:false, error:message, stack:String(error?.stack || '')}); output.dataset.status='failed';
}
finally { compiler?.close(); }
