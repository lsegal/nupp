// How long the browser compiler may take to answer one request.
//
// The first request whose source `require`s a standard-library module checks
// that module graph from source (#109), and every later request reuses it. In
// headless CI browsers that first compile took 64 s in Chromium, 70 s in
// Firefox and 83 s in WebKit, and 147 s in WebKit on a slow runner. Startup
// takes 1-2 s and every later request at most about 6 s. So only a request
// that reaches a module no earlier response has checked gets
// IMPORT_DEADLINE_MS, about 1.6 times the worst measured first compile; every
// other request keeps DEADLINE_MS.
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
