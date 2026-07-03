#!/usr/bin/env node
// ShadowzDex co-pilot — natural language → an attestor-signed intent that fills
// on the live IntentRouter on Robinhood Chain testnet.
//
//   node copilot/copilot.mjs "buy $100 of TSLA"
//
// Flow:  NL ──Fireworks──▶ {side, symbol, usdc}
//        ──▶ build SwapIntent ──▶ read router.hashIntent() (EIP-712 digest)
//        ──▶ attestor signs the digest ──▶ user submits router.executeSwap()
//
// Env (from ../.env): DEPLOYER_PK (the user), ATTESTOR_PK, FIREWORKS_API_KEY.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient, createWalletClient, http, defineChain,
  keccak256, toHex, maxUint256, formatUnits, parseUnits,
} from "viem";
import { privateKeyToAccount, sign, serializeSignature } from "viem/accounts";

const __dir = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(readFileSync(join(__dir, "markets.json"), "utf8"));

// ── env ──
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

const chain = defineChain({
  id: cfg.chainId, name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [cfg.rpc] } },
});

// ── minimal ABIs ──
const SWAP_INTENT = {
  type: "tuple", components: [
    { name: "user", type: "address" }, { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" },
    { name: "minOut", type: "uint256" }, { name: "deadline", type: "uint256" },
    { name: "venue", type: "bytes32" }, { name: "nonce", type: "uint256" },
    { name: "extra", type: "bytes" }, { name: "bridgeFeeAmount", type: "uint256" },
    { name: "sdmTier", type: "uint8" },
  ],
};
const routerAbi = [
  { name: "hashIntent", type: "function", stateMutability: "view", inputs: [SWAP_INTENT], outputs: [{ type: "bytes32" }] },
  { name: "executeSwap", type: "function", stateMutability: "nonpayable",
    inputs: [SWAP_INTENT, { name: "signature", type: "bytes" }, { name: "adapterData", type: "bytes" }],
    outputs: [{ type: "uint256" }] },
];
const poolAbi = [{ name: "quote", type: "function", stateMutability: "view",
  inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] }];
const erc20Abi = [
  { name: "allowance", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
];

// ── 1. parse NL with Fireworks ──
async function parse(instruction) {
  const symbols = Object.keys(cfg.markets).join(", ");
  const body = {
    model: "accounts/fireworks/models/gpt-oss-120b",
    temperature: 0, max_tokens: 200,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content:
        `You turn a spoken trading instruction into JSON. Tradeable tokenized stocks: ${symbols}. ` +
        `They are bought/sold with USDC. Respond ONLY with JSON: ` +
        `{"side":"buy"|"sell","symbol":"<one of ${symbols}>","usdc":<number of US dollars>}. ` +
        `"usdc" is the dollar size of the trade. If the user names a dollar amount, use it.` },
      { role: "user", content: instruction },
    ],
  };
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${need("FIREWORKS_API_KEY")}` },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}: ${await r.text()}`);
  const j = await r.json();
  return JSON.parse(j.choices[0].message.content);
}

async function main() {
  const instruction = process.argv.slice(2).join(" ").trim();
  if (!instruction) { console.error('usage: node copilot.mjs "buy $100 of TSLA"'); process.exit(1); }

  console.log(`\n🗣️  "${instruction}"`);
  const intent0 = await parse(instruction);
  const sym = String(intent0.symbol || "").toUpperCase();
  const mkt = cfg.markets[sym];
  if (!mkt) { console.error(`✗ unknown/unsupported symbol: ${intent0.symbol}. Tradeable: ${Object.keys(cfg.markets).join(", ")}`); process.exit(1); }
  if (intent0.side !== "buy") { console.error(`✗ this MVP demos buys; got "${intent0.side}". (sell = same path, tokenIn=stock)`); process.exit(1); }
  const usdc = Number(intent0.usdc);
  if (!(usdc > 0)) { console.error(`✗ couldn't read a dollar amount`); process.exit(1); }
  console.log(`🤖 parsed → buy $${usdc} of ${sym} (${mkt.name})`);

  const norm = (k) => (k.startsWith("0x") ? k : `0x${k}`);
  const userPk = norm(need("DEPLOYER_PK"));
  const attestorPk = norm(need("ATTESTOR_PK"));
  const user = privateKeyToAccount(userPk);
  const attestor = privateKeyToAccount(attestorPk);
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = createWalletClient({ account: user, chain, transport: http() });

  const amountIn = parseUnits(String(usdc), 6); // USDC 6-dec
  const expOut = await pub.readContract({ address: mkt.pool, abi: poolAbi, functionName: "quote", args: [cfg.usdc, amountIn] });
  console.log(`📈 quote: ~${formatUnits(expOut, 18)} ${sym}  (via ShadowzDex ${mkt.venue} pool)`);

  const intent = {
    user: user.address, tokenIn: cfg.usdc, tokenOut: mkt.stock,
    amountIn, minOut: (expOut * 98n) / 100n,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
    venue: keccak256(toHex(mkt.venue)),
    nonce: BigInt("0x" + [...crypto.getRandomValues(new Uint8Array(12))].map(b => b.toString(16).padStart(2, "0")).join("")),
    extra: "0x", bridgeFeeAmount: 0n, sdmTier: 0,
  };

  // attestor signs the router's EIP-712 digest
  const digest = await pub.readContract({ address: cfg.router, abi: routerAbi, functionName: "hashIntent", args: [intent] });
  const sig = serializeSignature(await sign({ hash: digest, privateKey: attestorPk }));
  console.log(`✍️  attestor ${attestor.address.slice(0, 8)}… signed the intent`);

  // ensure USDC allowance
  const allow = await pub.readContract({ address: cfg.usdc, abi: erc20Abi, functionName: "allowance", args: [user.address, cfg.router] });
  if (allow < amountIn) {
    console.log(`… approving USDC`);
    const h = await wallet.writeContract({ address: cfg.usdc, abi: erc20Abi, functionName: "approve", args: [cfg.router, maxUint256] });
    await pub.waitForTransactionReceipt({ hash: h });
  }

  const before = await pub.readContract({ address: mkt.stock, abi: erc20Abi, functionName: "balanceOf", args: [user.address] });
  console.log(`🚀 executeSwap …`);
  const hash = await wallet.writeContract({ address: cfg.router, abi: routerAbi, functionName: "executeSwap", args: [intent, sig, "0x"] });
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  const after = await pub.readContract({ address: mkt.stock, abi: erc20Abi, functionName: "balanceOf", args: [user.address] });

  console.log(`\n✅ filled — you received ${formatUnits(after - before, 18)} ${sym}`);
  console.log(`   status ${rcpt.status} · block ${rcpt.blockNumber}`);
  console.log(`   ${cfg.explorer}/tx/${hash}\n`);
}
main().catch((e) => { console.error("✗", e.message || e); process.exit(1); });
