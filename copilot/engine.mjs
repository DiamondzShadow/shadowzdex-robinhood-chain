// Trade engine for the ShadowzDex co-pilot — the shared, best-execution swap core
// used by the CLI co-pilot (copilot.mjs) and the portfolio agent (basket.mjs).
// Everything price-/route-/sign-related lives here so callers just say buy/sell.
//
// A swap is: quote every venue that lists the symbol (bestex.decide), drop any
// >5% off the Chainlink feed, route to the best single venue or SPLIT across
// venues, and execute each leg as its own oracle-checked, attestor-signed intent
// through the live IntentRouter — recording each fill in the tax-lot ledger.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient, createWalletClient, http, defineChain,
  keccak256, toHex, maxUint256, formatUnits, parseUnits, encodeAbiParameters,
} from "viem";
import { privateKeyToAccount, sign, serializeSignature } from "viem/accounts";
import * as ledger from "./ledger.mjs";
import { loadVenues, decide, adapterDataFor } from "./bestex.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
export const cfg = JSON.parse(readFileSync(join(__dir, "markets.json"), "utf8"));

export function loadEnv() {
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
export const env = loadEnv();
export const need = (k) => { if (!env[k]) { console.error(`missing ${k}`); process.exit(1); } return env[k]; };
const norm = (k) => (k.startsWith("0x") ? k : `0x${k}`);
export const usd = (n) => `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export const chain = defineChain({
  id: cfg.chainId, name: "Robinhood Chain",
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

export const symbols = () => Object.keys(cfg.markets);

// Build a trade context. Defaults to the env DEPLOYER_PK / ATTESTOR_PK single-user
// model; pass {userPk, attestorPk} to drive a different wallet.
export function makeCtx({ userPk, attestorPk } = {}) {
  const user = privateKeyToAccount(norm(userPk ?? need("DEPLOYER_PK")));
  const att = norm(attestorPk ?? need("ATTESTOR_PK"));
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = createWalletClient({ account: user, chain, transport: http() });
  const market = (sym) => {
    const m = cfg.markets[String(sym).toUpperCase()];
    if (!m) throw new Error(`unsupported symbol ${sym}. Tradeable: ${symbols().join(", ")}`);
    return m;
  };
  return { pub, wallet, user, attestorPk: att, market };
}

export async function oracleUsd(pub, mkt) {
  const [rd, dec] = await Promise.all([
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "latestRoundData" }),
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "decimals" }),
  ]);
  return Number(formatUnits(rd[1], dec));
}

// Execute one attestor-signed leg through a specific venue. adapterData is empty
// for constant-product pools and the encoded (router, path, feeOnTransfer) blob
// for Uniswap V2 venues. Returns { out, hash }.
async function execLeg(ctx, { venueName, tokenIn, tokenOut, amountIn, minOut, adapterData = "0x" }) {
  const intent = {
    user: ctx.user.address, tokenIn, tokenOut, amountIn, minOut,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600), venue: keccak256(toHex(venueName)),
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
  const hash = await ctx.wallet.writeContract({ address: cfg.router, abi: routerAbi, functionName: "executeSwap", args: [intent, sig, adapterData] });
  await ctx.pub.waitForTransactionReceipt({ hash });
  const after = await ctx.pub.readContract({ address: tokenOut, abi: erc20Abi, functionName: "balanceOf", args: [ctx.user.address] });
  return { out: after - before, hash };
}

// Best-execution swap. Quotes every venue that lists the symbol, drops any that
// deviate > maxDev from the Chainlink oracle, then routes to the best single
// venue — or SPLITS across venues. Set opts.quiet to suppress the routing log.
// Returns { out (bigint total), hash (primary), hashes }.
export async function doSwap(ctx, { mkt, sym, tokenIn, tokenOut, amountIn }, opts = {}) {
  const log = opts.quiet ? () => {} : console.log;
  const side = tokenIn.toLowerCase() === cfg.usdc.toLowerCase() ? "usdc" : "stock";
  const oracle = await oracleUsd(ctx.pub, mkt);
  // fall back to the legacy top-level pool/venue if a market has no venues[] array
  const venuesCfg = mkt.venues ?? [{ venue: mkt.venue, pool: mkt.pool, label: mkt.name }];
  const venues = await loadVenues(ctx.pub, venuesCfg, cfg.usdc);
  const maxDev = Number(env.ORACLE_MAX_DEV_BPS ?? cfg.oracleMaxDevBps ?? 500);
  const d = decide(venues, side, amountIn, { oracle, maxDevBps: maxDev });

  const fmtOut = (q) => (side === "usdc" ? `${Number(formatUnits(q, 18)).toFixed(6)} ${sym}` : usd(Number(formatUnits(q, 6))));
  log(`\n🔀 Best-execution — ${sym} · Chainlink ${usd(oracle)} · ${side === "usdc" ? "buy" : "sell"} across ${venues.length} venue(s):`);
  for (const v of d.table) { // d.table is the eligible venues with quotes precomputed
    log(`   • ${v.label.padEnd(22)} mid ${usd(v.mid)} (${v.devBps}bps) → ${fmtOut(v.out)}`);
  }
  for (const v of d.excluded) log(`   ✗ ${v.label.padEnd(22)} mid ${usd(v.mid)} (${v.devBps}bps) — 🔒 off-band, skipped`);
  if (!d.best) throw new Error(`attestor REFUSES — every ${sym} venue deviates > ${maxDev}bps from the Chainlink oracle`);

  let plan;
  const legFmt = (a) => (side === "usdc" ? usd(Number(formatUnits(a.amountIn, 6))) : `${Number(formatUnits(a.amountIn, 18)).toFixed(4)} ${sym}`);
  if (d.useSplit) {
    plan = d.split.allocations;
    log(`   ⇒ SPLIT across ${plan.length} venues (+${d.improvementBps}bps vs best single): ${plan.map((a) => `${a.key}=${legFmt(a)}`).join(" + ")}`);
  } else {
    plan = [{ ...d.best, amountIn }];
    log(`   ⇒ ROUTE all to ${d.best.label}${d.vsNaiveBps > 0 ? ` (+${d.vsNaiveBps}bps vs default ${sym}_MKT)` : " (best fill)"}`);
  }

  let totalOut = 0n; const hashes = [];
  for (const leg of plan) {
    const src = venues.find((v) => v.key === leg.key);
    const expLeg = leg.out; // precomputed by decide()/optimalSplit for this leg's amountIn
    const adapterData = adapterDataFor(src, tokenIn, tokenOut, encodeAbiParameters);
    const { out, hash } = await execLeg(ctx, { venueName: leg.key, tokenIn, tokenOut, amountIn: leg.amountIn, minOut: (expLeg * 98n) / 100n, adapterData });
    totalOut += out; hashes.push(hash);
  }
  return { out: totalOut, hash: hashes[0], hashes };
}

// Buy `dollars` of `sym` via best-ex; opens a tax lot. Returns { qty, costUsd, hashes }.
export async function buy(ctx, sym, dollars, opts = {}) {
  const mkt = ctx.market(sym);
  const amountIn = parseUnits(String(dollars), 6);
  const { out, hash, hashes } = await doSwap(ctx, { mkt, sym, tokenIn: cfg.usdc, tokenOut: mkt.stock, amountIn }, opts);
  const qty = Number(formatUnits(out, 18));
  await ledger.recordBuy({ wallet: ctx.user.address, symbol: sym, qty, costUsd: dollars, priceUsd: dollars / qty, txHash: hash });
  if (!opts.quiet) {
    console.log(`✅ bought ${qty.toFixed(6)} ${sym} for ${usd(dollars)}  (basis ${usd(dollars / qty)}/sh)`);
    for (const h of hashes) console.log(`   ${cfg.explorer}/tx/${h}`);
  }
  return { qty, costUsd: dollars, hashes };
}

// Sell `dollars` worth (or all) of `sym` via best-ex; consumes lots FIFO.
// Returns { qty, proceeds, realizedUsd, hashes } (or null if nothing held).
export async function sell(ctx, sym, { dollars, all }, opts = {}) {
  const mkt = ctx.market(sym);
  const held = await ledger.positionQty(ctx.user.address, sym);
  if (held <= 1e-9) { if (!opts.quiet) console.log(`ℹ️  no tracked ${sym} position to sell.`); return null; }
  const oracle = await oracleUsd(ctx.pub, mkt);
  const qty = all ? held : Math.min(held, dollars / oracle);
  const amountIn = parseUnits(qty.toFixed(12), 18);
  const { out, hash, hashes } = await doSwap(ctx, { mkt, sym, tokenIn: mkt.stock, tokenOut: cfg.usdc, amountIn }, opts);
  const proceeds = Number(formatUnits(out, 6));
  const { realizedUsd } = await ledger.recordSell({ wallet: ctx.user.address, symbol: sym, qty, proceedsUsd: proceeds, priceUsd: proceeds / qty, txHash: hash });
  if (!opts.quiet) {
    const tag = realizedUsd >= 0 ? "gain" : "loss";
    console.log(`✅ sold ${qty.toFixed(6)} ${sym} for ${usd(proceeds)} → realized ${tag} ${usd(realizedUsd)}`);
    for (const h of hashes) console.log(`   ${cfg.explorer}/tx/${h}`);
  }
  return { qty, proceeds, realizedUsd, hashes };
}

export { ledger };
