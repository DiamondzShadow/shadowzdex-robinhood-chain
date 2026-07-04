#!/usr/bin/env node
// One-off pool rebalancer. The testnet Chainlink stand-in feeds move over time
// (a keeper tracks Pool A), so a pool seeded at a stale price can drift outside
// the attestor's 5% oracle band and stop being routable. This walks each venue's
// constant-product pool back to its current oracle price with a single
// attestor-signed router swap — buying stock out with USDC when the pool is
// cheap, selling stock in when it's rich. It intentionally does NOT apply the
// oracle guard (that guard is what we're restoring). Run occasionally:
//
//   node copilot/rebalance.mjs            # rebalance every venue of every market
//   node copilot/rebalance.mjs TSLA       # just one symbol
//
// Uses DEPLOYER_PK (holds the tokens) + ATTESTOR_PK (signs) from ../.env.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient, createWalletClient, http, defineChain,
  keccak256, toHex, maxUint256, formatUnits,
} from "viem";
import { privateKeyToAccount, sign, serializeSignature } from "viem/accounts";

const __dir = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(readFileSync(join(__dir, "markets.json"), "utf8"));

function loadEnv() {
  const out = {};
  try {
    for (const line of readFileSync(join(__dir, "..", ".env"), "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {}
  return { ...out, ...process.env };
}
const env = loadEnv();
const norm = (k) => (k.startsWith("0x") ? k : `0x${k}`);
const need = (k) => { if (!env[k]) { console.error(`missing ${k}`); process.exit(1); } return env[k]; };

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
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "bool" }] },
];
// fix approve signature (spender, amount)
erc20Abi[1].inputs = [{ type: "address" }, { type: "uint256" }];

// integer sqrt (Newton) for bigints
function isqrt(n) {
  if (n < 2n) return n;
  let x = n, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + n / x) / 2n; }
  return x;
}

async function oracleUsd(pub, feed) {
  const [rd, dec] = await Promise.all([
    pub.readContract({ address: feed, abi: feedAbi, functionName: "latestRoundData" }),
    pub.readContract({ address: feed, abi: feedAbi, functionName: "decimals" }),
  ]);
  return { raw: rd[1], dec };
}

async function main() {
  const only = (process.argv[2] || "").toUpperCase() || null;
  const user = privateKeyToAccount(norm(need("DEPLOYER_PK")));
  const attestorPk = norm(need("ATTESTOR_PK"));
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = createWalletClient({ account: user, chain, transport: http() });

  for (const [sym, mkt] of Object.entries(cfg.markets)) {
    if (only && sym !== only) continue;
    const { raw: oRaw, dec: oDec } = await oracleUsd(pub, mkt.feed);
    const oracle = Number(formatUnits(oRaw, oDec));
    for (const v of mkt.venues) {
      const [rU, rS] = await Promise.all([
        pub.readContract({ address: v.pool, abi: poolAbi, functionName: "reserveUsdc" }),
        pub.readContract({ address: v.pool, abi: poolAbi, functionName: "reserveStock" }),
      ]);
      // price (USD/share) = rU*1e12 / rS   (USDC 6-dec, stock 18-dec)
      const priceCur = Number(rU) * 1e12 / Number(rS);
      const devBps = Math.round(Math.abs(priceCur - oracle) / oracle * 10000);
      if (devBps <= 200) { console.log(`✓ ${sym}/${v.label} $${priceCur.toFixed(2)} (dev ${devBps}bps) — in band, skip`); continue; }

      // Target reserves at oracle price, preserving k = rU*rS.
      //   rS' = sqrt(k * 1e12 / P),  scaled in integer domain.
      // P in raw = oracle * 1e6 (USDC units) per 1e18 stock → priceRaw = oracle*1e6/1e18 per unit.
      // Work in the raw invariant: want rU'/rS' = oracle/1e12  →  rS'^2 = k*1e12/oracle_raw6*... keep it numeric.
      const k = rU * rS; // raw invariant
      // rS' = sqrt( k * 1e12 / (oracle) ) with oracle as float → use scaled integer
      const oracleScaled = BigInt(Math.round(oracle * 1e6)); // 6-dec fixed
      // rS'^2 = k * 1e12 * 1e6 / oracleScaled  (keep 1e6 scaling consistent)
      const rSp = isqrt((k * (10n ** 18n)) / oracleScaled);
      let intent;
      if (rSp > rS) {
        // pool too expensive → SELL stock in (tokenIn = stock)
        const amountIn = rSp - rS;
        intent = { tokenIn: mkt.stock, tokenOut: cfg.usdc, amountIn };
        console.log(`↧ ${sym}/${v.label} $${priceCur.toFixed(2)}→$${oracle.toFixed(2)} · selling ${formatUnits(amountIn, 18)} ${sym} in`);
      } else {
        // pool too cheap → BUY stock out with USDC (tokenIn = usdc)
        const rUp = k / rSp;
        const amountIn = rUp - rU;
        intent = { tokenIn: cfg.usdc, tokenOut: mkt.stock, amountIn };
        console.log(`↥ ${sym}/${v.label} $${priceCur.toFixed(2)}→$${oracle.toFixed(2)} · buying with ${formatUnits(amountIn, 6)} USDC`);
      }
      await execute(pub, wallet, user, attestorPk, v.venue, intent);
    }
  }
  console.log("\ndone.");
}

async function execute(pub, wallet, user, attestorPk, venueName, { tokenIn, tokenOut, amountIn }) {
  if (amountIn <= 0n) { console.log("   (zero trade, skip)"); return; }
  const intent = {
    user: user.address, tokenIn, tokenOut, amountIn, minOut: 0n,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600), venue: keccak256(toHex(venueName)),
    nonce: BigInt("0x" + [...crypto.getRandomValues(new Uint8Array(12))].map((b) => b.toString(16).padStart(2, "0")).join("")),
    extra: "0x", bridgeFeeAmount: 0n, sdmTier: 0,
  };
  const digest = await pub.readContract({ address: cfg.router, abi: routerAbi, functionName: "hashIntent", args: [intent] });
  const sig = serializeSignature(await sign({ hash: digest, privateKey: attestorPk }));
  const allow = await pub.readContract({ address: tokenIn, abi: erc20Abi, functionName: "allowance", args: [user.address, cfg.router] });
  if (allow < amountIn) {
    const h = await wallet.writeContract({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [cfg.router, maxUint256] });
    await pub.waitForTransactionReceipt({ hash: h });
  }
  const hash = await wallet.writeContract({ address: cfg.router, abi: routerAbi, functionName: "executeSwap", args: [intent, sig, "0x"] });
  await pub.waitForTransactionReceipt({ hash });
  console.log(`   ✅ ${cfg.explorer}/tx/${hash}`);
}

main().catch((e) => { console.error("✗", e.message || e); process.exit(1); });
