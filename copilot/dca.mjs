#!/usr/bin/env node
// DCA keeper for ShadowzDex — recurring "buy $X of SYM every N" orders, fired
// through the best-execution engine (multi-venue + split + oracle guard) and
// booked to the tax-lot ledger. Built on engine.mjs, so each occurrence is a
// full best-ex buy; the keeper just decides WHEN.
//
//   node copilot/dca.mjs add TSLA 50 1w [--max 12] [--budget 600] [--start-next]
//   node copilot/dca.mjs add-nl "buy $50 of TSLA every week"
//   node copilot/dca.mjs list
//   node copilot/dca.mjs cancel <id>
//   node copilot/dca.mjs run                 # fire everything due once (cron-friendly)
//   node copilot/dca.mjs run --watch [--tick 15]   # local loop until no active schedules
//
// Custody: single-user model — the keeper signs with DEPLOYER_PK (same wallet the
// co-pilot uses). For multi-user, non-custodial DCA the IntentRouter already ships
// `executeSwapWithPermit2Keeper` (a relayer submits while the user's Permit2 witness
// binds the pull to one intent) — swap execLeg's path for that + a per-user permit.
//
// Scheduling: `run` is one-shot and cron/Temporal-friendly (invoke on your cadence
// via the existing shadowz-keeperz relayer rather than a bespoke long-lived process).
// `--watch` is a convenience for local demos.

import { makeCtx, buy, ledger, usd, need, symbols } from "./engine.mjs";
import * as store from "./dca-store.mjs";

const UNIT_SEC = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 };
const UNIT_WORD = { second: "s", seconds: "s", minute: "m", minutes: "m", hour: "h", hours: "h", day: "d", days: "d", week: "w", weeks: "w" };

function parseDur(str) {
  const m = String(str).trim().match(/^(\d+)\s*([smhdw])$/i);
  if (!m) throw new Error(`bad interval "${str}" — use e.g. 30s, 5m, 1h, 1d, 1w`);
  const u = m[2].toLowerCase();
  return { sec: Number(m[1]) * UNIT_SEC[u], label: `${m[1]}${u}` };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function inWords(ms) {
  const s = Math.round((ms - Date.now()) / 1000);
  if (s <= 0) return "now";
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}
const flagVal = (args, name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

async function cmdAdd(wallet, sym, dollars, interval, opts) {
  sym = String(sym).toUpperCase();
  if (!symbols().includes(sym)) throw new Error(`unsupported symbol ${sym}. Tradeable: ${symbols().join(", ")}`);
  dollars = Number(dollars);
  if (!(dollars > 0)) throw new Error("name a dollar amount, e.g. add TSLA 50 1w");
  const { sec, label } = parseDur(interval);
  const doc = await store.addSchedule({
    wallet, symbol: sym, usd: dollars, intervalSec: sec, intervalLabel: label,
    maxRuns: opts.max ? Number(opts.max) : null,
    budgetUsd: opts.budget ? Number(opts.budget) : null,
    firstRunAt: opts.startNext ? Date.now() + sec * 1000 : Date.now(),
  });
  console.log(`✅ DCA ${doc.sid}: buy ${usd(dollars)} of ${sym} every ${label}` +
    `${doc.maxRuns ? ` · max ${doc.maxRuns} runs` : ""}${doc.budgetUsd ? ` · budget ${usd(doc.budgetUsd)}` : ""}` +
    ` · first run ${inWords(doc.nextRunAt)}`);
}

async function cmdAddNl(wallet, instruction, opts) {
  const syms = symbols().join(", ");
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${need("FIREWORKS_API_KEY")}` },
    body: JSON.stringify({
      model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 160, response_format: { type: "json_object" },
      messages: [
        { role: "system", content:
          `Turn a recurring-buy instruction into JSON for a DCA agent. Symbols: ${syms}. ` +
          `Respond ONLY with JSON: {"symbol":<one of ${syms}>,"usd":<dollars>,"count":<integer>,"unit":"second"|"minute"|"hour"|"day"|"week"}. ` +
          `"buy $50 of TSLA every week"→{"symbol":"TSLA","usd":50,"count":1,"unit":"week"}. ` +
          `"put $10 into AMD every 2 days"→{"symbol":"AMD","usd":10,"count":2,"unit":"day"}.` },
        { role: "user", content: instruction },
      ],
    }),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}`);
  const raw = (await r.json()).choices?.[0]?.message?.content ?? "";
  let a;
  try { a = JSON.parse(raw); }
  catch { // some models wrap the JSON in reasoning tokens — take the last flat {...}
    const ms = raw.match(/\{[^{}]*\}/g);
    if (!ms) throw new Error(`could not parse "${instruction}" — try: add ${symbols()[0]} 50 1w`);
    a = JSON.parse(ms[ms.length - 1]);
  }
  const u = UNIT_WORD[String(a.unit).toLowerCase()];
  if (!u) throw new Error(`could not parse interval from "${instruction}"`);
  return cmdAdd(wallet, a.symbol, a.usd, `${a.count}${u}`, opts);
}

async function cmdList() {
  const all = await store.listSchedules();
  if (!all.length) { console.log("no DCA schedules."); return; }
  console.log(`\n⏰ DCA schedules:`);
  for (const s of all) {
    const caps = [s.maxRuns ? `${s.runs}/${s.maxRuns} runs` : `${s.runs} runs`, s.budgetUsd ? `${usd(s.spentUsd)}/${usd(s.budgetUsd)}` : `${usd(s.spentUsd)} spent`].join(" · ");
    const state = s.active ? `next ${inWords(s.nextRunAt)}` : "done/cancelled";
    console.log(`   ${s.sid}  ${usd(s.usd)} ${s.symbol.padEnd(4)} every ${s.intervalLabel.padEnd(4)} · ${caps} · ${state}${s.lastError ? `  ⚠️ ${s.lastError}` : ""}`);
  }
}

async function cmdCancel(sid) {
  const ok = await store.cancelSchedule(sid);
  console.log(ok ? `✅ cancelled ${sid}` : `no schedule ${sid}`);
}

// One keeper tick: fire every schedule that's due. Returns count fired.
async function runDue(ctx) {
  const due = await store.dueSchedules();
  if (!due.length) { console.log("· nothing due."); return 0; }
  let fired = 0;
  for (const s of due) {
    console.log(`\n⏰ DCA ${s.sid} — buy ${usd(s.usd)} of ${s.symbol} (run ${s.runs + 1}${s.maxRuns ? "/" + s.maxRuns : ""})`);
    try {
      const { qty, costUsd, hashes } = await buy(ctx, s.symbol, s.usd);
      const res = await store.recordRun(s.sid, { ok: true, nextRunAt: Date.now() + s.intervalSec * 1000, spentDelta: costUsd, txHashes: hashes, qty });
      fired++;
      if (res.deactivated) console.log(`   🏁 ${s.sid} complete (${res.hitMax ? "max runs" : "budget"} reached).`);
      else console.log(`   ↻ next ${s.symbol} buy in ${s.intervalLabel}`);
    } catch (e) {
      const backoff = Math.min(s.intervalSec, 60);
      await store.recordRun(s.sid, { ok: false, nextRunAt: Date.now() + backoff * 1000, error: String(e.message || e).slice(0, 120) });
      console.log(`   ⚠️ skipped: ${e.message || e} — retry in ${backoff}s`);
    }
  }
  return fired;
}

async function cmdRun(ctx, watch, tickSec) {
  if (!watch) { await runDue(ctx); return; }
  for (;;) {
    await runDue(ctx);
    const active = (await store.listSchedules()).filter((s) => s.active);
    if (!active.length) { console.log("\n✅ no active schedules — keeper idle, exiting."); break; }
    const nextAt = Math.min(...active.map((s) => s.nextRunAt));
    console.log(`· sleeping ${tickSec}s (next due ${inWords(nextAt)})…`);
    await sleep(tickSec * 1000);
  }
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const usage = 'usage: dca.mjs add <SYM> <usd> <interval> [--max n] [--budget usd] [--start-next] | add-nl "..." | list | cancel <id> | run [--watch] [--tick s]';
  if (!cmd) { console.error(usage); process.exit(1); }

  const opts = { max: flagVal(args, "--max"), budget: flagVal(args, "--budget"), startNext: args.includes("--start-next") };
  const pos = args.filter((a) => !a.startsWith("--") && a !== opts.max && a !== opts.budget);

  try {
    if (cmd === "list") return void (await cmdList());
    if (cmd === "cancel") return void (await cmdCancel(pos[0] || die("cancel <id>")));

    // Commands below need the wallet address / chain.
    const ctx = makeCtx();
    const wallet = ctx.user.address;
    if (cmd === "add") await cmdAdd(wallet, pos[0], pos[1], pos[2], opts);
    else if (cmd === "add-nl") await cmdAddNl(wallet, pos.join(" "), opts);
    else if (cmd === "run") await cmdRun(ctx, args.includes("--watch"), Number(flagVal(args, "--tick") || 15));
    else throw new Error(usage);
  } finally {
    await Promise.all([ledger.close().catch(() => {}), store.close().catch(() => {})]);
  }
}
function die(m) { throw new Error(m); }
main().catch(async (e) => { console.error("✗", e.message || e); await Promise.all([ledger.close().catch(() => {}), store.close().catch(() => {})]); process.exit(1); });
