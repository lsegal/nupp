// Per-suite totals from a `nupp test --json` report: suite, cases, failures, seconds.
const j = require(process.argv[2]);
const by = {};
for (const t of j.tests || []) {
  const s = (by[t.suite] ||= { n: 0, f: 0, ms: 0 });
  s.n++; s.ms += t.durationMs || 0;
  if (t.status === "failed") { s.f++; console.log("FAIL", t.id, (t.failure && t.failure.message || "").slice(0, 300).replace(/\n/g, " ")); }
}
console.log("total", j.total, "passed", j.passed, "failed", j.failed);
for (const [k, v] of Object.entries(by).sort((a, b) => b[1].ms - a[1].ms)) console.log("SUITE", k, v.n, v.f, (v.ms / 1000).toFixed(1));
