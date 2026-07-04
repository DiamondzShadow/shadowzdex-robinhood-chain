#!/usr/bin/env node
// Limit / stop-loss keeper for ShadowzDex — conditional orders that fire once when
// the Chainlink price crosses a trigger, executed through the best-execution engine
// and booked to the tax ledger. Same store+engine shape as the DCA keeper (dca.mjs);
// the only difference is a PRICE trigger instead of a TIME trigger.
//
// The four order types fall out of (action × direction):
//   limit-buy    buy  when price ≤ trigger   (buy the dip)
//   stop-buy     buy  when price ≥ trigger   (breakout)
//   take-profit  sell when price ≥ trigger   (sell the rip)
//   stop-loss    sell when price ≤ trigger   (cut losses)
//
//   node copilot/orders.mjs add buy  TSLA 100 below 350        # limit buy
//   node copilot/orders.mjs add sell TSLA all  above 400       # take-profit
//   node copilot/orders.mjs add sell AMD  all  below 150 --expires 7d   # stop-loss, GTD
//   node copilot/orders.mjs add-nl "sell my TSLA if it hits $400"
//   node copilot/orders.mjs list
//   node copilot/orders.mjs cancel <id>
//   node copilot/orders.mjs run                 # check triggers once (cron/Temporal-friendly)
//   node copilot/orders.mjs run --watch --tick 15
//
// Custody / scheduling notes are the same as dca.mjs (single-user DEPLOYER_PK;
// `run` one-shot for cron/keeper, `--watch` for local demos).

import { makeCtx, buy, sell, oracleUsd, ledger, usd, need, symbols } from "./engine.mjs";
import * as store from "./order-store.mjs";

const DIR = { below: "below", under: "below", down: "below", "<=": "below", "<": "below",
              above: "above", over: "above", up: "above", ">=": "above", ">": "above" };
const UNIT_SEC = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 };

function parseDur(str) {
  const m = String(str).trim().match(/^(\d+)\s*([smhdw])$/i);
  if (!m) throw new Error(`bad duration "${str}" — use e.g. 1h, 7d, 2w`);
  return Number(m[1]) * UNIT_SEC[m[2].toLowerCase()] * 1000;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flagVal = (a, n) => { const i = a.indexOf(n); return i >= 0 ? a[i + 1] : undefined; };

function orderType(action, direction) {
  return action === "buy"
    ? (direction === "below" ? "limit-buy" : "stop-buy")
    : (direction === "below" ? "stop-loss" : "take-profit");
}
const arrowOf = (d) => (d === "below" ? "≤" : "≥");
const triggered = (o, price) => (o.direction === "below" ? price <= o.trigger : price >= o.trigger);

async function cmdAdd(wallet, ctx, { action, sym, amount, dir, trigger, expiresSec }) {
  action = String(action).toLowerCase();
  if (action !== "buy" && action !== "sell") throw new Error(`action must be buy|sell`);
  sym = String(sym).toUpperCase();
  if (!symbols().includes(sym)) throw new Error(`unsupported symbol ${sym}. Tradeable: ${symbols().join(", ")}`);
  const direction = DIR[String(dir).toLowerCase()];
  if (!direction) throw new Error(`direction must be below|above (got "${dir}")`);
  const trig = Number(trigger);
  if (!(trig > 0)) throw new Error(`trigger price must be > 0`);

  const all = String(amount).toLowerCase() === "all";
  const dollars = all ? null : Number(amount);
  if (action === "buy" && all) throw new Error(`a buy needs a dollar amount, not "all"`);
  if (!all && !(dollars > 0)) throw new Error(`amount must be a dollar figure or "all"`);

  const doc = await store.addOrder({
    wallet, action, symbol: sym, trigger: trig, direction, usd: dollars, all,
    expiresAt: expiresSec ? Date.now() + expiresSec : null,
  });
  console.log(`✅ ${orderType(action, direction)} ${doc.sid}: ${action} ${all ? "all" : usd(dollars)} ${sym} when price ${arrowOf(direction)} ${usd(trig)}` +
    `${doc.expiresAt ? ` · expires ${new Date(doc.expiresAt).toISOString().slice(0, 16).replace("T", " ")}` : ""}`);

  // Immediate-fire notice (market-if-touched): warn if the condition already holds.
  const price = await oracleUsd(ctx.pub, ctx.market(sym));
  if (triggered(doc, price)) console.log(`   ⚠️ already satisfied — Chainlink ${sym} ${usd(price)} ${arrowOf(direction)} ${usd(trig)}; will fire on the next \`run\`.`);
  else console.log(`   Chainlink ${sym} now ${usd(price)} — waiting to cross ${usd(trig)}.`);
}

async function cmdAddNl(wallet, ctx, instruction) {
  const syms = symbols().join(", ");
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${need("FIREWORKS_API_KEY")}` },
    body: JSON.stringify({
      model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 400, response_format: { type: "json_object" },
      messages: [
        { role: "system", content:
          `Turn a conditional-order instruction into JSON for a limit/stop-loss agent. Symbols: ${syms}. ` +
          `Respond ONLY with JSON: {"action":"buy"|"sell","symbol":<sym>,"amount":<dollars or "all">,"direction":"below"|"above","trigger":<price>}. ` +
          `direction is the price move that fires it: "sell if it hits/rises to X"→above; "sell if it drops/falls to X" or "stop loss at X"→below; ` +
          `"buy if it dips to X"→below; "buy if it breaks X"→above. ` +
          `"sell my TSLA if it hits $400"→{"action":"sell","symbol":"TSLA","amount":"all","direction":"above","trigger":400}. ` +
          `"buy $100 of AMD if it dips to 150"→{"action":"buy","symbol":"AMD","amount":100,"direction":"below","trigger":150}. ` +
          `"stop loss my TSLA at 320"→{"action":"sell","symbol":"TSLA","amount":"all","direction":"below","trigger":320}.` },
        { role: "user", content: instruction },
      ],
    }),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}`);
  const rawc = (await r.json()).choices?.[0]?.message?.content ?? "";
  let a;
  try { a = JSON.parse(rawc); }
  catch { const ms = rawc.match(/\{[^{}]*\}/g); if (!ms) throw new Error(`could not parse "${instruction}"`); a = JSON.parse(ms[ms.length - 1]); }
  return cmdAdd(wallet, ctx, { action: a.action, sym: a.symbol, amount: a.amount, dir: a.direction, trigger: a.trigger });
}

async function cmdList() {
  const all = await store.listOrders();
  if (!all.length) { console.log("no orders."); return; }
  console.log(`\n🎯 Orders:`);
  for (const o of all) {
    const amt = o.all ? "all" : usd(o.usd);
    const cond = `${o.symbol} ${arrowOf(o.direction)} ${usd(o.trigger)}`;
    const state = o.active ? "open" : o.status;
    console.log(`   ${o.sid}  ${orderType(o.action, o.direction).padEnd(11)} ${o.action} ${amt} ${cond.padEnd(18)} · ${state}`);
  }
}

async function cmdCancel(sid) {
  const ok = await store.cancelOrder(sid);
  console.log(ok ? `✅ cancelled ${sid}` : `no open order ${sid}`);
}

// One keeper tick: check every open order's trigger; execute the ones that crossed.
async function checkAll(ctx) {
  const open = await store.openOrders();
  if (!open.length) { console.log("· no open orders."); return 0; }
  const now = Date.now();
  const priceCache = {};
  let fired = 0;
  for (const o of open) {
    if (o.expiresAt && now > o.expiresAt) {
      await store.resolveOrder(o.sid, { status: "expired" });
      console.log(`⌛ ${o.sid} expired (${orderType(o.action, o.direction)} ${o.symbol} @ ${usd(o.trigger)})`);
      continue;
    }
    const price = priceCache[o.symbol] ??= await oracleUsd(ctx.pub, ctx.market(o.symbol));
    if (!triggered(o, price)) {
      console.log(`· ${o.sid} ${orderType(o.action, o.direction)} ${o.symbol} — ${usd(price)} not ${arrowOf(o.direction)} ${usd(o.trigger)}, waiting`);
      continue;
    }
    console.log(`\n🎯 ${o.sid} TRIGGERED — ${orderType(o.action, o.direction)} ${o.symbol}: Chainlink ${usd(price)} ${arrowOf(o.direction)} ${usd(o.trigger)}`);
    try {
      if (o.action === "buy") {
        const { qty, hashes } = await buy(ctx, o.symbol, o.usd);
        await store.resolveOrder(o.sid, { status: "filled", txHashes: hashes, price, qty });
      } else {
        const res = await sell(ctx, o.symbol, { dollars: o.usd, all: o.all });
        if (!res) { await store.resolveOrder(o.sid, { status: "nofill", price }); console.log(`   (no ${o.symbol} position — order closed)`); continue; }
        await store.resolveOrder(o.sid, { status: "filled", txHashes: res.hashes, price, qty: res.qty });
      }
      fired++;
    } catch (e) {
      // e.g. the oracle guard refusing an off-band pool — leave open, retry next tick.
      console.log(`   ⚠️ ${String(e.message || e).slice(0, 120)} — leaving order open, retry next tick`);
    }
  }
  return fired;
}

async function cmdRun(ctx, watch, tickSec) {
  if (!watch) { await checkAll(ctx); return; }
  for (;;) {
    await checkAll(ctx);
    const open = await store.openOrders();
    if (!open.length) { console.log("\n✅ no open orders — keeper idle, exiting."); break; }
    console.log(`· sleeping ${tickSec}s (${open.length} order(s) open)…`);
    await sleep(tickSec * 1000);
  }
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const usage = 'usage: orders.mjs add <buy|sell> <SYM> <usd|all> <below|above> <trigger> [--expires 7d] | add-nl "..." | list | cancel <id> | run [--watch] [--tick s]';
  if (!cmd) { console.error(usage); process.exit(1); }
  const expiresStr = flagVal(args, "--expires");
  const pos = args.filter((a) => !a.startsWith("--") && a !== expiresStr);

  try {
    if (cmd === "list") return void (await cmdList());
    if (cmd === "cancel") return void (await cmdCancel(pos[0] || die("cancel <id>")));

    const ctx = makeCtx();
    const wallet = ctx.user.address;
    if (cmd === "add") await cmdAdd(wallet, ctx, { action: pos[0], sym: pos[1], amount: pos[2], dir: pos[3], trigger: pos[4], expiresSec: expiresStr ? parseDur(expiresStr) : null });
    else if (cmd === "add-nl") await cmdAddNl(wallet, ctx, pos.join(" "));
    else if (cmd === "run") await cmdRun(ctx, args.includes("--watch"), Number(flagVal(args, "--tick") || 15));
    else throw new Error(usage);
  } finally {
    await Promise.all([ledger.close().catch(() => {}), store.close().catch(() => {})]);
  }
}
function die(m) { throw new Error(m); }
main().catch(async (e) => { console.error("✗", e.message || e); await Promise.all([ledger.close().catch(() => {}), store.close().catch(() => {})]); process.exit(1); });
