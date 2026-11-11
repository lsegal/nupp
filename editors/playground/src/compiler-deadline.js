// How long the browser compiler may take to answer one request.
//
// The compiler carries the checked interfaces of the standard-library modules
// the playground's examples reach (#109), so a first `require` of one of those
// decodes them. A module outside that image is still checked from source the
// first time a request reaches it, and every later request reuses it. Before
// the image, that first check of the `coroutine` graph took 64 s in Chromium,
// 70 s in Firefox and 83 s in WebKit in headless CI browsers, and 147 s in
// WebKit on a slow runner. So only a request that reaches a module no earlier
// response has checked gets IMPORT_DEADLINE_MS, about 1.6 times that worst
// case; every other request keeps DEADLINE_MS.
export const DEADLINE_MS = 30000;
export const IMPORT_DEADLINE_MS = 240000;

const REQUIRE = /\brequire\s*\(?\s*(["'])([^"'\r\n]+)\1/g;

export function requiredModules(source) {
  return typeof source === 'string' ? [...new Set([...source.matchAll(REQUIRE)].map(match => match[2]))] : [];
}

export function createDeadlines({deadlineMs = DEADLINE_MS, importDeadlineMs = IMPORT_DEADLINE_MS} = {}) {
  const checked = new Set();
  return {
    deadlineMs,
    // A module counts as checked once a response that reached it arrives, so
    // a request that failed or expired leaves the next one the longer deadline.
    async request(compiler, request) {
      const fresh = requiredModules(request.source).filter(name => !checked.has(name));
      const response = await compiler.request(request, {deadlineMs: fresh.length ? importDeadlineMs : deadlineMs});
      for (const name of fresh) checked.add(name);
      return response;
    },
  };
}
