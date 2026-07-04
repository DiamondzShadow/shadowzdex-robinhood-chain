#!/usr/bin/env node
// ShadowzDex tax-aware co-pilot — natural language → oracle-checked, attestor-signed
// best-execution trades on Robinhood Chain, with a MongoDB tax-lot ledger underneath.
// The trade engine lives in engine.mjs; this is the natural-language CLI over it.
//
//   node copilot/copilot.mjs "buy $100 of TSLA"
//   node copilot/copilot.mjs "sell all my AMD"
//   node copilot/copilot.mjs "harvest my losses"
//   node copilot/copilot.mjs "show my taxes"

import { need, usd, makeCtx, oracleUsd, buy, sell, ledger, symbols } from "./engine.mjs";

// ── NL → structured action ──
async function parse(instruction) {
  const syms = symbols().join(", ");
  const body = {
    model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 200,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content:
        `You turn a spoken trading instruction into JSON for a tokenized-stock trading agent. ` +
        `Tradeable symbols: ${syms} (traded vs USDC). Respond ONLY with JSON: ` +
        `{"action":"buy"|"sell"|"harvest"|"report","symbol":<one of ${syms} or null>,"usd":<dollars or null>,"all":<true if they say "all"/"everything">}. ` +
        `"buy $100 of TSLA"→{"action":"buy","symbol":"TSLA","usd":100,"all":false}. ` +
        `"sell all my AMD"→{"action":"sell","symbol":"AMD","usd":null,"all":true}. ` +
        `"harvest my AMD losses"→{"action":"harvest","symbol":"AMD","usd":null,"all":false}. ` +
        `"harvest my losses"→{"action":"harvest","symbol":null,"usd":null,"all":false}. ` +
        `"show my taxes"/"how am I doing"→{"action":"report","symbol":null,"usd":null,"all":false}.` },
      { role: "user", content: instruction },
    ],
  };
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${need("FIREWORKS_API_KEY")}` },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}: ${await r.text()}`);
  return JSON.parse((await r.json()).choices[0].message.content);
}

async function harvest(ctx, symOpt) {
  const { positions } = await ledger.report(ctx.user.address);
  const syms = symOpt ? [symOpt] : Object.keys(positions);
  let total = 0, harvested = 0;
  for (const sym of syms) {
    const p = positions[sym];
    if (!p || p.qty <= 1e-9) continue;
    const oracle = await oracleUsd(ctx.pub, ctx.market(sym));
    const basisPerSh = p.costUsd / p.qty;
    const unreal = (oracle - basisPerSh) * p.qty;
    if (unreal < 0) {
      console.log(`\n📉 ${sym}: ${p.qty.toFixed(4)} sh · basis ${usd(basisPerSh)} · Chainlink ${usd(oracle)} · unrealized loss ${usd(unreal)} → harvesting`);
      const r = await sell(ctx, sym, { all: true });
      harvested += r ? r.realizedUsd : 0; total += 1;
    } else {
      console.log(`🟢 ${sym}: up ${usd(unreal)} — skipping (a sale would realize a gain)`);
    }
  }
  console.log(`\n🧾 harvested ${total} position(s) · total realized loss ${usd(harvested)} — booked to your YTD to offset gains.`);
}

async function report(ctx) {
  const { positions, realizedYtd, realizedRows } = await ledger.report(ctx.user.address);
  console.log(`\n📒 Tax report — ${ctx.user.address}`);
  console.log(`\nOpen positions (mark-to-Chainlink):`);
  const syms = Object.keys(positions);
  if (!syms.length) console.log("   (none)");
  for (const sym of syms) {
    const p = positions[sym];
    const oracle = await oracleUsd(ctx.pub, ctx.market(sym));
    const mv = oracle * p.qty, unreal = mv - p.costUsd;
    console.log(`   ${sym.padEnd(5)} ${p.qty.toFixed(4)} sh · basis ${usd(p.costUsd)} · value ${usd(mv)} · unrealized ${unreal >= 0 ? "+" : ""}${usd(unreal)}`);
  }
  console.log(`\nRealized P/L (YTD): ${realizedYtd >= 0 ? "+" : ""}${usd(realizedYtd)}  (Form 8949 rows:)`);
  for (const r of realizedRows) {
    const d = new Date(r.ts).toISOString().slice(0, 10);
    console.log(`   ${d}  SOLD ${r.sellQty.toFixed(4)} ${r.symbol} · proceeds ${usd(r.proceedsUsd)} · ${r.realizedUsd >= 0 ? "gain" : "loss"} ${usd(r.realizedUsd)}`);
  }
  if (!realizedRows.length) console.log("   (no sales yet)");
}

async function main() {
  const instruction = process.argv.slice(2).join(" ").trim();
  if (!instruction) { console.error('usage: node copilot.mjs "buy $100 of TSLA" | "harvest my losses" | "show my taxes"'); process.exit(1); }
  console.log(`\n🗣️  "${instruction}"`);
  const a = await parse(instruction);
  console.log(`🤖 ${a.action}${a.symbol ? " " + a.symbol : ""}${a.usd ? " $" + a.usd : ""}${a.all ? " (all)" : ""}`);

  const ctx = makeCtx();
  try {
    const sym = a.symbol && String(a.symbol).toUpperCase();
    if (a.action === "buy") await buy(ctx, sym, Number(a.usd));
    else if (a.action === "sell") await sell(ctx, sym, { dollars: Number(a.usd), all: !!a.all });
    else if (a.action === "harvest") await harvest(ctx, sym || null);
    else if (a.action === "report") await report(ctx);
    else throw new Error(`unknown action ${a.action}`);
  } finally {
    await ledger.close();
  }
}
main().catch(async (e) => { console.error("✗", e.message || e); await ledger.close().catch(() => {}); process.exit(1); });
