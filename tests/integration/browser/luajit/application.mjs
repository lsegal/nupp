import {runNuppLuaJITApp} from '../../../../runtime/luajit/app-runtime.mjs';
import {createCompiler} from '../../../../runtime/luajit/host.mjs';
const output = document.querySelector('#result');
const terminal = document.querySelector('#terminal');
const bytes = async name => new Uint8Array(await (await fetch(name)).arrayBuffer());
// The first compile checks the standard-library graph its `require`s reach,
// which every later one reuses. Startup takes 1-2 s and later compiles under a
// second, but WebKit's first compile took 75 s on a typical CI runner and 147 s
// on a slow one, against at most 94 s in Chromium or Firefox. Only WebKit's
// first request gets room past the shared deadline.
const webkit = /AppleWebKit/.test(navigator.userAgent) && !/Chrome|Chromium|Edg/.test(navigator.userAgent);
const deadlineMs = 120000, firstDeadlineMs = webkit ? 240000 : deadlineMs;
let compiler, name;
try {
  const started = performance.now();
  compiler = await createCompiler({manifestUrl: './guest-manifest.json', app: await bytes('./compiler.ljbc'), deadlineMs});
  const startupMs = performance.now() - started;
  const initialize = await bytes('./app-runtime.lua');
  const sources = await (await fetch('./application-sources.json')).json();
  const results = [];
  for (const [index, [entry, source]] of Object.entries(sources).entries()) {
    name = entry;
    terminal.textContent = name;
    const compileStarted = performance.now();
    const compiled = await compiler.request({kind:'compile', source, filename:'playground.nupp', options:{strict:true, optimize:true}},
      {deadlineMs: index === 0 ? firstDeadlineMs : deadlineMs});
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
