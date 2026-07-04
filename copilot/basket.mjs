#!/usr/bin/env node
// Portfolio agent for ShadowzDex — thematic baskets + target-weight rebalancing,
// every leg routed through the best-execution engine (multi-venue + split + oracle
// guard) and booked to the tax-lot ledger. Built on engine.mjs, so a basket buy
// or a rebalance is just N best-ex swaps.
//
//   node copilot/basket.mjs list
//   node copilot/basket.mjs show TECH
//   node copilot/basket.mjs define TECH "TSLA=50,AMD=30,AMZN=20"
//   node copilot/basket.mjs buy TECH 200                 # buy $200 spread by weight
//   node copilot/basket.mjs rebalance TECH               # restore target weights
//   node copilot/basket.mjs rebalance --weights "TSLA=40,AMD=30,AMZN=30"
//   node copilot/basket.mjs nl "buy me $150 of the tech basket"

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { makeCtx, oracleUsd, buy, sell, ledger, cfg, usd, need, symbols } from "./engine.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const USER_BASKETS = join(__dir, "user-baskets.json");

// Built-in baskets over the tradeable symbols. Weights are normalised on load.
const BUILTIN = {
  EQUAL:  { TSLA: 1, AMD: 1, AMZN: 1 },
  TECH:   { TSLA: 0.40, AMZN: 0.35, AMD: 0.25 },
  AICHIP: { AMD: 0.50, TSLA: 0.30, AMZN: 0.20 },
};

const round2 = (n) => Math.round(n * 100) / 100;

function normalize(weights) {
  const known = symbols();
  const out = {};
  let sum = 0;
  for (const [k, v] of Object.entries(weights)) {
    const sym = k.toUpperCase();
    if (!known.includes(sym)) throw new Error(`unknown symbol ${sym}. Tradeable: ${known.join(", ")}`);
    if (v < 0) throw new Error(`negative weight for ${sym}`);
    out[sym] = (out[sym] || 0) + Number(v); sum += Number(v);
  }
  if (sum <= 0) throw new Error("weights sum to zero");
  for (const k of Object.keys(out)) out[k] /= sum;
  return out;
}

function parseWeights(spec) {
  // "TSLA=50,AMD=30,AMZN=20" → { TSLA: .5, AMD: .3, AMZN: .2 }
  const w = {};
  for (const part of spec.split(",")) {
    const [sym, val] = part.split("=").map((s) => s.trim());
    if (!sym || val === undefined || val === "") throw new Error(`bad weight spec near "${part}"`);
    w[sym] = Number(val);
  }
  return normalize(w);
}

function loadUserBaskets() {
  if (!existsSync(USER_BASKETS)) return {};
  try { return JSON.parse(readFileSync(USER_BASKETS, "utf8")); } catch { return {}; }
}
function allBaskets() {
  const user = loadUserBaskets();
  const merged = {};
  for (const [name, w] of Object.entries({ ...BUILTIN, ...user })) merged[name.toUpperCase()] = normalize(w);
  return merged;
}
function getBasket(name) {
  const b = allBaskets()[String(name).toUpperCase()];
  if (!b) throw new Error(`unknown basket ${name}. Try: ${Object.keys(allBaskets()).join(", ")}`);
  return b;
}

const fmtWeights = (w) => Object.entries(w).map(([s, x]) => `${s} ${(x * 100).toFixed(1)}%`).join(" · ");

// ── current value of a set of symbols, marked to Chainlink ──
async function markValues(ctx, syms) {
  const { positions } = await ledger.report(ctx.user.address);
  const out = {};
  let total = 0;
  for (const sym of syms) {
    const qty = positions[sym]?.qty ?? 0;
    const oracle = await oracleUsd(ctx.pub, ctx.market(sym));
    const value = qty * oracle;
    out[sym] = { qty, oracle, value };
    total += value;
  }
  return { marks: out, total };
}

// ── commands ──
function cmdList() {
  const b = allBaskets();
  console.log(`\n📦 Baskets:`);
  for (const [name, w] of Object.entries(b)) console.log(`   ${name.padEnd(8)} ${fmtWeights(w)}`);
}

function cmdShow(name) {
  console.log(`\n📦 ${name.toUpperCase()}: ${fmtWeights(getBasket(name))}`);
}

function cmdDefine(name, spec) {
  const w = parseWeights(spec);
  const user = loadUserBaskets();
  user[name.toUpperCase()] = w;
  writeFileSync(USER_BASKETS, JSON.stringify(user, null, 2));
  console.log(`\n✅ saved basket ${name.toUpperCase()}: ${fmtWeights(w)}`);
}

async function cmdBuy(ctx, name, dollars, dry) {
  const w = getBasket(name);
  dollars = Number(dollars);
  if (!(dollars > 0)) throw new Error("name a dollar amount, e.g. buy TECH 200");
  console.log(`\n🧺 Buy ${usd(dollars)} of ${name.toUpperCase()} — ${fmtWeights(w)}`);
  const plan = Object.entries(w).map(([sym, x]) => [sym, round2(dollars * x)]).filter(([, d]) => d >= 0.01);
  for (const [sym, d] of plan) console.log(`   → ${sym}: ${usd(d)}`);
  if (dry) { console.log(`   (dry-run — no trades executed)`); return; }
  const legs = [];
  for (const [sym, d] of plan) {
    const r = await buy(ctx, sym, d);
    legs.push({ sym, ...r });
  }
  const spent = legs.reduce((s, l) => s + l.costUsd, 0);
  console.log(`\n✅ bought the ${name.toUpperCase()} basket — ${usd(spent)} across ${legs.length} positions.`);
}

async function cmdRebalance(ctx, name, weights, dry) {
  const w = weights || getBasket(name);
  const syms = Object.keys(w);
  const label = name ? name.toUpperCase() : "target";
  console.log(`\n⚖️  Rebalance to ${label} — ${fmtWeights(w)}`);

  const { marks, total } = await markValues(ctx, syms);
  if (total < 1) {
    console.log(`   portfolio holds ${usd(total)} of these symbols — nothing to rebalance. Use "buy ${label} <usd>" to open the basket.`);
    return;
  }
  // Drift + trade plan. Threshold avoids dust trades.
  const threshold = Math.max(1, 0.02 * total);
  console.log(`   portfolio value (these symbols): ${usd(total)} · trade threshold ${usd(threshold)}`);
  const sells = [], buys = [];
  for (const sym of syms) {
    const cur = marks[sym].value;
    const target = total * w[sym];
    const delta = target - cur;
    const curPct = total > 0 ? (cur / total) * 100 : 0;
    const tag = delta > threshold ? "BUY" : delta < -threshold ? "SELL" : "hold";
    console.log(`   ${sym.padEnd(5)} now ${usd(cur)} (${curPct.toFixed(1)}%) → target ${usd(target)} (${(w[sym] * 100).toFixed(1)}%) · Δ ${delta >= 0 ? "+" : ""}${usd(delta)}  ${tag}`);
    if (delta > threshold) buys.push([sym, round2(delta)]);
    else if (delta < -threshold) sells.push([sym, round2(-delta)]);
  }
  if (!sells.length && !buys.length) { console.log(`\n✅ already within ${usd(threshold)} of target — no trades needed.`); return; }
  if (dry) { console.log(`\n   (dry-run — plan: ${sells.length} sell(s), ${buys.length} buy(s); no trades executed)`); return; }

  // Sell overweights first (frees USDC), then buy underweights.
  for (const [sym, d] of sells) await sell(ctx, sym, { dollars: d });
  for (const [sym, d] of buys) await buy(ctx, sym, d);
  console.log(`\n✅ rebalanced ${label}: ${sells.length} sell(s), ${buys.length} buy(s).`);
}

// Natural-language front-end → routes to the commands above.
async function cmdNl(ctx, instruction, dry) {
  const syms = symbols().join(", ");
  const names = Object.keys(allBaskets()).join(", ");
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${need("FIREWORKS_API_KEY")}` },
    body: JSON.stringify({
      model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 200, response_format: { type: "json_object" },
      messages: [
        { role: "system", content:
          `You turn a portfolio instruction into JSON for a basket agent. Symbols: ${syms}. Known baskets: ${names}. ` +
          `Respond ONLY with JSON: {"action":"buy"|"rebalance","basket":<name or null>,"usd":<dollars or null>,"weights":<"SYM=pct,..." or null>}. ` +
          `"buy $150 of the tech basket"→{"action":"buy","basket":"TECH","usd":150,"weights":null}. ` +
          `"rebalance me to equal weight"→{"action":"rebalance","basket":"EQUAL","usd":null,"weights":null}. ` +
          `"keep me 40/30/30 across TSLA AMD AMZN"→{"action":"rebalance","basket":null,"usd":null,"weights":"TSLA=40,AMD=30,AMZN=30"}.` },
        { role: "user", content: instruction },
      ],
    }),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}`);
  const a = JSON.parse((await r.json()).choices[0].message.content);
  console.log(`🤖 ${a.action}${a.basket ? " " + a.basket : ""}${a.usd ? " $" + a.usd : ""}${a.weights ? " [" + a.weights + "]" : ""}`);
  if (a.action === "buy") return cmdBuy(ctx, a.basket, a.usd, dry);
  if (a.action === "rebalance") return cmdRebalance(ctx, a.basket, a.weights ? parseWeights(a.weights) : null, dry);
  throw new Error(`unsupported instruction`);
}

async function main() {
  const argv = process.argv.slice(2);
  const dry = argv.includes("--dry");
  const [cmd, ...rest] = argv.filter((a) => a !== "--dry");
  const usage = 'usage: basket.mjs list | show <name> | define <name> "SYM=pct,..." | buy <name> <usd> | rebalance <name> | rebalance --weights "SYM=pct,..." | nl "..."  [--dry]';
  if (!cmd) { console.error(usage); process.exit(1); }

  // Read-only commands need no chain/keys.
  if (cmd === "list") return cmdList();
  if (cmd === "show") return cmdShow(rest[0] || die("show <name>"));
  if (cmd === "define") return cmdDefine(rest[0], rest.slice(1).join(" "));

  const ctx = makeCtx();
  try {
    if (cmd === "buy") await cmdBuy(ctx, rest[0], rest[1], dry);
    else if (cmd === "rebalance") {
      if (rest[0] === "--weights") await cmdRebalance(ctx, null, parseWeights(rest.slice(1).join(" ")), dry);
      else await cmdRebalance(ctx, rest[0] || die("rebalance <name>"), null, dry);
    } else if (cmd === "nl") await cmdNl(ctx, rest.join(" "), dry);
    else throw new Error(usage);
  } finally {
    await ledger.close();
  }
}
function die(m) { throw new Error(m); }
main().catch(async (e) => { console.error("✗", e.message || e); await ledger.close().catch(() => {}); process.exit(1); });
