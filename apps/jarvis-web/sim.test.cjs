// Zero-dependency proof suite for the jarvis-web sim engine.
// Run: node apps/jarvis-web/sim.test.js
const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
const m = html.match(/\/\* JARVIS-SIM-ENGINE-START[\s\S]*?window\.JarvisSim = (\(function[\s\S]*?\}\)\(\));[\s\S]*?JARVIS-SIM-ENGINE-END/);
if (!m) { console.error("FAIL engine block not found"); process.exit(1); }
const Sim = (0, eval)(m[1]);

let pass = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log("PASS " + name); }
  else { console.log("FAIL " + name + (extra ? " :: " + extra : "")); process.exitCode = 1; }
}

// Layers
ok("layers-seven", Sim.LAYERS.length === 7);
ok("layers-order", Sim.LAYERS.map((l) => l.id).join() === "app,apple,router,llama,llamacpp,openrouter,vector");
ok("layers-hex", Sim.LAYERS.every((l) => /^#[0-9a-f]{6}$/i.test(l.color)));
ok("layerById-unknown", Sim.layerById("nope") === null);

// Routing
ok("classify-lease", Sim.classify("Summarize the lease") === "cloud");
ok("classify-legal", Sim.classify("eviction dispute court") === "cloud");
ok("classify-local", Sim.classify("Well pump pressure low") === "local");
ok("classify-empty", Sim.classify("") === "local");
ok("answer-maple", Sim.answerFor("Who is Maple?").indexOf("SA-104") >= 0);
ok("answer-herd", Sim.answerFor("how many animals").indexOf("12 animals") >= 0);
ok("answer-unknown", Sim.answerFor("rent notice") === "");

// Runs
const ALL = { apple: true, llama: true, llamacpp: true, openrouter: true, vector: true };
const lease = Sim.buildRun("lease", "", ALL);
ok("lease-cloud", lease.want === "cloud" && !lease.error);
ok("lease-phases", lease.phases.map((p) => p.layer).join() === "apple,router,openrouter,vector,app");
ok("lease-path", lease.path.join().indexOf("openrouter") >= 0 && lease.path[0] === "app");
const triage = Sim.buildRun("triage", "", ALL);
ok("triage-local", triage.want === "local");
ok("triage-total", triage.totalMs === 200 + 300 + 500 + 1200 + 400 + 300, String(triage.totalMs));
ok("triage-path", triage.path.join() === "app,apple,router,llamacpp,llama,vector,app", triage.path.join());
const noCloud = Sim.buildRun("lease", "", Object.assign({}, ALL, { openrouter: false }));
ok("toggle-cloud-fallback", noCloud.want === "local" && noCloud.notes.join().indexOf("falling back") >= 0);
const noLocal = Sim.buildRun("triage", "", Object.assign({}, ALL, { llama: false }));
ok("toggle-local-escalate", noLocal.want === "cloud" && noLocal.notes.join().indexOf("escalating") >= 0);
const noGen = Sim.buildRun("triage", "", Object.assign({}, ALL, { llama: false, openrouter: false }));
ok("toggle-no-gen", !!noGen.error && noGen.phases.length === 0);
const noApple = Sim.buildRun("triage", "", Object.assign({}, ALL, { apple: false }));
ok("toggle-apple-skip", noApple.phases.every((p) => p.layer !== "apple"));
const custom = Sim.buildRun(null, "Draft eviction clause review", ALL);
ok("custom-cloud", custom.want === "cloud" && custom.intent === "property.general");

// Ticks
const t0 = Sim.tickRun(triage, 0);
ok("tick-apple", t0.active === "apple" && t0.leds.apple === "active" && !t0.done);
const t1 = Sim.tickRun(triage, 250);
ok("tick-router-thinking", t1.active === "router" && t1.leds.router === "thinking" && t1.log.length === 1);
const t2 = Sim.tickRun(triage, 1500);
ok("tick-llama", t2.active === "llama" && t2.leds.llama === "active");
const t3 = Sim.tickRun(triage, 99999);
ok("tick-done", t3.done && t3.active === "" && t3.log.length === 6 && t3.tokens > 0, JSON.stringify([t3.log.length, t3.tokens]));
ok("tick-empty", Sim.tickRun({ phases: [] }, 0).done === true);

// Format
ok("stamp-zero", Sim.formatStamp(0) === "[00:00]");
ok("stamp-min", Sim.formatStamp(61000) === "[01:01]");
ok("format-log", Sim.formatLog({ tMs: 1200, msg: "hi" }) === "[00:01] hi");

// Particles
const yOf = (id) => ({ app: 6.6, apple: 4.4, router: 2.2, llama: 0, llamacpp: -2.2, openrouter: -4.4, vector: -6.6 }[id]);
const spots = Sim.particleSpots(triage.path, yOf, 70, 1.5);
ok("spots-count", spots.length === 70);
ok("spots-range", spots.every((s) => s.y <= 6.6 && s.y >= -6.6 && Math.abs(s.x) <= 1 && Math.abs(s.z) <= 1));
ok("spots-local-cyan", spots.some((s) => s.color === "#22d3ee") && spots.every((s) => s.color !== "#f0abfc"));
const cspots = Sim.particleSpots(lease.path, yOf, 70, 1.5);
ok("spots-cloud-magenta", cspots.some((s) => s.color === "#f0abfc") && cspots.some((s) => s.color === "#f8fafc"));
ok("spots-deterministic", JSON.stringify(Sim.particleSpots(triage.path, yOf, 5, 2)) === JSON.stringify(Sim.particleSpots(triage.path, yOf, 5, 2)));
ok("spots-empty", Sim.particleSpots(["app"], yOf, 10, 1).length === 0);

// Env
ok("env-localhost", Sim.envFromHostname("localhost", null) === "dev");
ok("env-dev-ip", Sim.envFromHostname("100.85.188.74", null) === "dev");
ok("env-intelmini", Sim.envFromHostname("intelmini.local", null) === "prod");
ok("env-prod-ip", Sim.envFromHostname("100.85.36.72", null) === "prod");
ok("env-myprod-stays-dev", Sim.envFromHostname("myprod.local", null) === "dev");
ok("env-query-wins", Sim.envFromHostname("intelmini.local", "dev") === "dev" && Sim.envFromHostname("x", "prod") === "prod");
ok("env-caption-dev", Sim.ENV_CAPTION.dev === "DEV fixture · sample herd · read only");

console.log(pass + " passed" + (process.exitCode ? " WITH FAILURES" : ""));
