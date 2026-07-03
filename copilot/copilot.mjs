#!/usr/bin/env node
// ShadowzDex tax-aware co-pilot — natural language → oracle-checked, attestor-signed
// trades on Robinhood Chain, with a MongoDB tax-lot ledger underneath.
//
//   node copilot/copilot.mjs "buy $100 of TSLA"
//   node copilot/copilot.mjs "sell all my AMD"
//   node copilot/copilot.mjs "harvest my losses"
//   node copilot/copilot.mjs "show my taxes"

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient, createWalletClient, http, defineChain,
  keccak256, toHex, maxUint256, formatUnits, parseUnits,
} from "viem";
import { privateKeyToAccount, sign, serializeSignature } from "viem/accounts";
import * as ledger from "./ledger.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(readFileSync(join(__dir, "markets.json"), "utf8"));

function loadEnv() {
  const out = {};
  for (const p of [join(__dir, "..", ".env"), join(process.env.HOME, ".fireworks.env")]) {
    try {
      for (const line of readFileSync(p, "utf8").split("\n")) {
        const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
        if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
    } catch {}
  }
  return { ...out, ...process.env };
}
const env = loadEnv();
const need = (k) => { if (!env[k]) { console.error(`missing ${k}`); process.exit(1); } return env[k]; };
const norm = (k) => (k.startsWith("0x") ? k : `0x${k}`);

const chain = defineChain({
  id: cfg.chainId, name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [cfg.rpc] } },
});

const SWAP_INTENT = { type: "tuple", components: [
  { name: "user", type: "address" }, { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
  { name: "amountIn", type: "uint256" }, { name: "minOut", type: "uint256" }, { name: "deadline", type: "uint256" },
  { name: "venue", type: "bytes32" }, { name: "nonce", type: "uint256" }, { name: "extra", type: "bytes" },
  { name: "bridgeFeeAmount", type: "uint256" }, { name: "sdmTier", type: "uint8" } ] };
const routerAbi = [
  { name: "hashIntent", type: "function", stateMutability: "view", inputs: [SWAP_INTENT], outputs: [{ type: "bytes32" }] },
  { name: "executeSwap", type: "function", stateMutability: "nonpayable",
    inputs: [SWAP_INTENT, { name: "signature", type: "bytes" }, { name: "adapterData", type: "bytes" }], outputs: [{ type: "uint256" }] },
];
const poolAbi = [
  { name: "quote", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "reserveUsdc", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "reserveStock", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];
const feedAbi = [
  { name: "latestRoundData", type: "function", stateMutability: "view", inputs: [], outputs: [
    { type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] },
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];
const erc20Abi = [
  { name: "allowance", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
];

// ── NL → structured action ──
async function parse(instruction) {
  const symbols = Object.keys(cfg.markets).join(", ");
  const body = {
    model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 200,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content:
        `You turn a spoken trading instruction into JSON for a tokenized-stock trading agent. ` +
        `Tradeable symbols: ${symbols} (traded vs USDC). Respond ONLY with JSON: ` +
        `{"action":"buy"|"sell"|"harvest"|"report","symbol":<one of ${symbols} or null>,"usd":<dollars or null>,"all":<true if they say "all"/"everything">}. ` +
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

const usd = (n) => `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

async function oracleUsd(pub, mkt) {
  const [rd, dec] = await Promise.all([
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "latestRoundData" }),
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "decimals" }),
  ]);
  return Number(formatUnits(rd[1], dec));
}
async function oracleGuard(pub, mkt, sym) {
  const [rU, rS] = await Promise.all([
    pub.readContract({ address: mkt.pool, abi: poolAbi, functionName: "reserveUsdc" }),
    pub.readContract({ address: mkt.pool, abi: poolAbi, functionName: "reserveStock" }),
  ]);
  const spot = Number(formatUnits(rU, 6)) / Number(formatUnits(rS, 18));
  const oracle = await oracleUsd(pub, mkt);
  const devBps = Math.round((Math.abs(spot - oracle) / oracle) * 10000);
  const maxDev = Number(env.ORACLE_MAX_DEV_BPS ?? cfg.oracleMaxDevBps ?? 500);
  console.log(`🔗 Chainlink ${sym}/USD ${usd(oracle)} · pool ${usd(spot)} · dev ${devBps}bps (max ${maxDev})`);
  if (devBps > maxDev) throw new Error(`attestor REFUSES to sign — pool deviates ${devBps}bps from the Chainlink oracle (> ${maxDev})`);
  return oracle;
}

// oracle-checked, attestor-signed swap through the live router. Returns raw out (bigint).
async function doSwap(ctx, { mkt, sym, tokenIn, tokenOut, amountIn }) {
  await oracleGuard(ctx.pub, mkt, sym);
  const expOut = await ctx.pub.readContract({ address: mkt.pool, abi: poolAbi, functionName: "quote", args: [tokenIn, amountIn] });
  const intent = {
    user: ctx.user.address, tokenIn, tokenOut, amountIn, minOut: (expOut * 98n) / 100n,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600), venue: keccak256(toHex(mkt.venue)),
    nonce: BigInt("0x" + [...crypto.getRandomValues(new Uint8Array(12))].map((b) => b.toString(16).padStart(2, "0")).join("")),
    extra: "0x", bridgeFeeAmount: 0n, sdmTier: 0,
  };
  const digest = await ctx.pub.readContract({ address: cfg.router, abi: routerAbi, functionName: "hashIntent", args: [intent] });
  const sig = serializeSignature(await sign({ hash: digest, privateKey: ctx.attestorPk }));
  const allow = await ctx.pub.readContract({ address: tokenIn, abi: erc20Abi, functionName: "allowance", args: [ctx.user.address, cfg.router] });
  if (allow < amountIn) {
    const h = await ctx.wallet.writeContract({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [cfg.router, maxUint256] });
    await ctx.pub.waitForTransactionReceipt({ hash: h });
  }
  const before = await ctx.pub.readContract({ address: tokenOut, abi: erc20Abi, functionName: "balanceOf", args: [ctx.user.address] });
  const hash = await ctx.wallet.writeContract({ address: cfg.router, abi: routerAbi, functionName: "executeSwap", args: [intent, sig, "0x"] });
  await ctx.pub.waitForTransactionReceipt({ hash });
  const after = await ctx.pub.readContract({ address: tokenOut, abi: erc20Abi, functionName: "balanceOf", args: [ctx.user.address] });
  return { out: after - before, hash };
}

async function buy(ctx, sym, dollars) {
  const mkt = ctx.market(sym);
  const amountIn = parseUnits(String(dollars), 6);
  const { out, hash } = await doSwap(ctx, { mkt, sym, tokenIn: cfg.usdc, tokenOut: mkt.stock, amountIn });
  const qty = Number(formatUnits(out, 18));
  await ledger.recordBuy({ wallet: ctx.user.address, symbol: sym, qty, costUsd: dollars, priceUsd: dollars / qty, txHash: hash });
  console.log(`✅ bought ${qty.toFixed(6)} ${sym} for ${usd(dollars)}  (basis ${usd(dollars / qty)}/sh)`);
  console.log(`   ${cfg.explorer}/tx/${hash}`);
}

async function sell(ctx, sym, { dollars, all }) {
  const mkt = ctx.market(sym);
  const held = await ledger.positionQty(ctx.user.address, sym);
  if (held <= 1e-9) { console.log(`ℹ️  no tracked ${sym} position to sell.`); return 0; }
  const oracle = await oracleUsd(ctx.pub, mkt);
  let qty = all ? held : Math.min(held, dollars / oracle);
  const amountIn = parseUnits(qty.toFixed(12), 18);
  const { out, hash } = await doSwap(ctx, { mkt, sym, tokenIn: mkt.stock, tokenOut: cfg.usdc, amountIn });
  const proceeds = Number(formatUnits(out, 6));
  const { realizedUsd } = await ledger.recordSell({ wallet: ctx.user.address, symbol: sym, qty, proceedsUsd: proceeds, priceUsd: proceeds / qty, txHash: hash });
  const tag = realizedUsd >= 0 ? "gain" : "loss";
  console.log(`✅ sold ${qty.toFixed(6)} ${sym} for ${usd(proceeds)} → realized ${tag} ${usd(realizedUsd)}`);
  console.log(`   ${cfg.explorer}/tx/${hash}`);
  return realizedUsd;
}

async function harvest(ctx, symOpt) {
  const { positions } = await ledger.report(ctx.user.address);
  const syms = symOpt ? [symOpt] : Object.keys(positions);
  let total = 0, harvested = 0;
  for (const sym of syms) {
    const p = positions[sym];
    if (!p || p.qty <= 1e-9) continue;
    const mkt = ctx.market(sym);
    const oracle = await oracleUsd(ctx.pub, mkt);
    const basisPerSh = p.costUsd / p.qty;
    const unreal = (oracle - basisPerSh) * p.qty;
    if (unreal < 0) {
      console.log(`\n📉 ${sym}: ${p.qty.toFixed(4)} sh · basis ${usd(basisPerSh)} · Chainlink ${usd(oracle)} · unrealized loss ${usd(unreal)} → harvesting`);
      const r = await sell(ctx, sym, { all: true });
      harvested += r; total += 1;
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

  const user = privateKeyToAccount(norm(need("DEPLOYER_PK")));
  const attestorPk = norm(need("ATTESTOR_PK"));
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = createWalletClient({ account: user, chain, transport: http() });
  const market = (sym) => {
    const m = cfg.markets[String(sym).toUpperCase()];
    if (!m) throw new Error(`unsupported symbol ${sym}. Tradeable: ${Object.keys(cfg.markets).join(", ")}`);
    return m;
  };
  const ctx = { pub, wallet, user, attestorPk, market };

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
