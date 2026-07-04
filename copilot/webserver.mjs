#!/usr/bin/env node
// Public co-pilot API + dApp host. SAFE TO EXPOSE:
//   - The server only PARSES (Fireworks), oracle-checks, and ATTESTOR-SIGNS the
//     intent. It never holds or spends user funds.
//   - The user's own browser wallet submits approve + executeSwap. The router
//     enforces msg.sender == intent.user, so a signed intent is worthless to
//     anyone but its owner.
//
//   PORT=8800 node copilot/webserver.mjs

import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createPublicClient, http as vhttp, defineChain, keccak256, toHex, formatUnits, parseUnits, encodeAbiParameters } from "viem";
import { sign, serializeSignature } from "viem/accounts";
import * as ledger from "./ledger.mjs";
import { loadVenues, decide, adapterDataFor } from "./bestex.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(readFileSync(join(__dir, "markets.json"), "utf8"));
const PORT = Number(process.env.PORT || 8800);

function env() {
  const out = {};
  for (const p of [join(__dir, "..", ".env"), join(process.env.HOME, ".fireworks.env")]) {
    try { for (const l of readFileSync(p, "utf8").split("\n")) { const m = l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/); if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, ""); } } catch {}
  }
  return out;
}
const E = env();
const ATTESTOR_PK = (E.ATTESTOR_PK || "").startsWith("0x") ? E.ATTESTOR_PK : `0x${E.ATTESTOR_PK}`;

const chain = defineChain({ id: cfg.chainId, name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [cfg.rpc] } } });
const pub = createPublicClient({ chain, transport: vhttp() });

const feedAbi = [
  { name: "latestRoundData", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] },
  { name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];
const SWAP_INTENT = { type: "tuple", components: [
  { name: "user", type: "address" }, { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
  { name: "amountIn", type: "uint256" }, { name: "minOut", type: "uint256" }, { name: "deadline", type: "uint256" },
  { name: "venue", type: "bytes32" }, { name: "nonce", type: "uint256" }, { name: "extra", type: "bytes" },
  { name: "bridgeFeeAmount", type: "uint256" }, { name: "sdmTier", type: "uint8" } ] };
const routerAbi = [{ name: "hashIntent", type: "function", stateMutability: "view", inputs: [SWAP_INTENT], outputs: [{ type: "bytes32" }] }];

async function oracleUsd(mkt) {
  const [rd, dec] = await Promise.all([
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "latestRoundData" }),
    pub.readContract({ address: mkt.feed, abi: feedAbi, functionName: "decimals" }),
  ]);
  return Number(formatUnits(rd[1], dec));
}
async function parse(instruction) {
  const symbols = Object.keys(cfg.markets).join(", ");
  const r = await fetch("https://api.fireworks.ai/inference/v1/chat/completions", {
    method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${E.FIREWORKS_API_KEY}` },
    body: JSON.stringify({ model: "accounts/fireworks/models/gpt-oss-120b", temperature: 0, max_tokens: 160, response_format: { type: "json_object" },
      messages: [
        { role: "system", content:
          `You turn a spoken trading instruction into JSON for a tokenized-stock agent. ` +
          `Tradeable symbols: ${symbols} (traded vs USDC). Respond ONLY with JSON: ` +
          `{"action":"buy"|"report","symbol":<one of ${symbols} or null>,"usd":<dollars or null>}. ` +
          `"buy $100 of TSLA"->{"action":"buy","symbol":"TSLA","usd":100}. ` +
          `"show my taxes"/"how am I doing"/"my positions"->{"action":"report","symbol":null,"usd":null}.` },
        { role: "user", content: instruction } ] }),
  });
  if (!r.ok) throw new Error(`Fireworks ${r.status}`);
  const content = (await r.json())?.choices?.[0]?.message?.content;
  if (!content) throw new Error("could not understand that — try 'buy $50 of TSLA' or 'show my taxes'");
  return JSON.parse(content);
}

const j = (o) => JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v));

async function handleIntent(body) {
  const wallet = String(body.wallet || "");
  if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) return { status: 400, body: { error: "connect a wallet first" } };
  const a = await parse(String(body.message || ""));
  const sym = a.symbol && String(a.symbol).toUpperCase();

  if (a.action === "report") {
    const rep = await ledger.report(wallet);
    const positions = [];
    for (const s of Object.keys(rep.positions)) {
      const p = rep.positions[s]; const oracle = await oracleUsd(cfg.markets[s]);
      positions.push({ symbol: s, qty: p.qty, basisUsd: p.costUsd, valueUsd: oracle * p.qty, oracle });
    }
    return { status: 200, body: { kind: "report", positions, realizedYtd: rep.realizedYtd } };
  }

  if (a.action !== "buy") return { status: 200, body: { kind: "note", message: "This web MVP supports 'buy $X of SYM' and 'show my taxes'." } };
  const mkt = cfg.markets[sym];
  if (!mkt) return { status: 400, body: { error: `unsupported symbol. Tradeable: ${Object.keys(cfg.markets).join(", ")}` } };
  const dollars = Number(a.usd);
  if (!(dollars > 0)) return { status: 400, body: { error: "name a dollar amount, e.g. buy $100 of TSLA" } };

  const amountIn = parseUnits(String(dollars), 6);
  const oracle = await oracleUsd(mkt);
  const maxDev = Number(cfg.oracleMaxDevBps ?? 500);
  // Best-execution: quote every venue that lists the symbol, drop off-band ones,
  // route the order to the best eligible venue. (The CLI co-pilot additionally
  // SPLITS across venues; the browser keeps a single-submit UX.)
  const venuesCfg = mkt.venues ?? [{ venue: mkt.venue, pool: mkt.pool, label: mkt.name }];
  const venues = await loadVenues(pub, venuesCfg, cfg.usdc);
  const d = decide(venues, "usdc", amountIn, { oracle, maxDevBps: maxDev });
  const routing = d.table // eligible venues with quotes precomputed
    .map((v) => ({ venue: v.key, label: v.label, mid: v.mid, devBps: v.devBps, out: v.out.toString() }))
    .concat(d.excluded.map((v) => ({ venue: v.key, label: v.label, mid: v.mid, devBps: v.devBps, out: null, offBand: true })));
  if (!d.best) return { status: 200, body: { kind: "rejected", symbol: sym, oracle, maxDev, routing, message: `Attestor refuses: every ${sym} venue deviates > ${maxDev}bps from the Chainlink oracle.` } };

  const bestSrc = venues.find((v) => v.key === d.best.key);
  const expOut = d.best.out;
  const adapterData = adapterDataFor(bestSrc, cfg.usdc, mkt.stock, encodeAbiParameters);
  const intent = {
    user: wallet, tokenIn: cfg.usdc, tokenOut: mkt.stock, amountIn, minOut: (expOut * 98n) / 100n,
    deadline: BigInt(Math.floor(Date.now() / 1000) + 600), venue: keccak256(toHex(d.best.key)),
    nonce: BigInt("0x" + [...crypto.getRandomValues(new Uint8Array(12))].map((b) => b.toString(16).padStart(2, "0")).join("")),
    extra: "0x", bridgeFeeAmount: 0n, sdmTier: 0,
  };
  const digest = await pub.readContract({ address: cfg.router, abi: routerAbi, functionName: "hashIntent", args: [intent] });
  const signature = serializeSignature(await sign({ hash: digest, privateKey: ATTESTOR_PK }));
  return { status: 200, body: { kind: "buy", symbol: sym, dollars, expOut: expOut.toString(), oracle, spot: d.best.mid, routedVenue: d.best.key, routedLabel: d.best.label, vsNaiveBps: d.vsNaiveBps, routing, intent, signature, adapterData, router: cfg.router, usdc: cfg.usdc } };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type", "access-control-allow-methods": "GET,POST,OPTIONS" };
  if (req.method === "OPTIONS") { res.writeHead(204, cors); return res.end(); }
  try {
    if (req.method === "GET" && url.pathname === "/") { res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return res.end(readFileSync(join(__dir, "public", "app.html"))); }
    if (req.method === "GET" && url.pathname === "/api/config") {
      res.writeHead(200, { "content-type": "application/json", ...cors });
      return res.end(j({ chainId: cfg.chainId, rpc: cfg.rpc, explorer: cfg.explorer, router: cfg.router, usdc: cfg.usdc, markets: cfg.markets }));
    }
    if (req.method === "POST" && (url.pathname === "/api/intent" || url.pathname === "/api/record")) {
      let raw = ""; for await (const c of req) raw += c;
      const body = raw ? JSON.parse(raw) : {};
      if (url.pathname === "/api/record") {
        await ledger.recordBuy({ wallet: body.wallet, symbol: body.symbol, qty: Number(body.qty), costUsd: Number(body.costUsd), priceUsd: Number(body.costUsd) / Number(body.qty), txHash: body.tx });
        res.writeHead(200, { "content-type": "application/json", ...cors }); return res.end(j({ ok: true }));
      }
      const out = await handleIntent(body);
      res.writeHead(out.status, { "content-type": "application/json", ...cors }); return res.end(j(out.body));
    }
    res.writeHead(404, cors); res.end("not found");
  } catch (e) {
    res.writeHead(500, { "content-type": "application/json", ...cors }); res.end(j({ error: String(e.message || e) }));
  }
});
server.listen(PORT, "127.0.0.1", () => console.log(`co-pilot dApp API on 127.0.0.1:${PORT}`));
