// Tax-lot ledger for the ShadowzDex co-pilot, backed by MongoDB Atlas.
// Every buy opens a lot (cost basis); every sell consumes open lots FIFO and
// realizes gain/loss; harvesting sells lots whose basis is above the Chainlink
// price. Amounts are kept in whole tokens / USD (floats) — fine for a testnet
// demo; a production ledger would use integer minor units.

import { readFileSync } from "node:fs";
import { MongoClient } from "mongodb";

function loadMongoEnv() {
  const env = {};
  try {
    for (const l of readFileSync(process.env.HOME + "/.brmg-mongo.env", "utf8").split("\n")) {
      const m = l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {}
  return env;
}

let _client, _lots, _realized;
async function cols() {
  if (_lots) return { lots: _lots, realized: _realized };
  const env = loadMongoEnv();
  _client = new MongoClient(env.MONGO_URI, { serverSelectionTimeoutMS: 8000 });
  await _client.connect();
  const db = _client.db(env.MONGO_DB || "brmg_catalog");
  _lots = db.collection("rh_tax_lots");
  _realized = db.collection("rh_tax_realized");
  await _lots.createIndex({ wallet: 1, symbol: 1, status: 1, ts: 1 });
  return { lots: _lots, realized: _realized };
}

const lc = (a) => String(a).toLowerCase();
const yearStart = () => Date.UTC(new Date().getUTCFullYear(), 0, 1);

export async function recordBuy({ wallet, symbol, qty, costUsd, priceUsd, txHash, ts }) {
  const { lots } = await cols();
  await lots.insertOne({
    wallet: lc(wallet), symbol, qty, remaining: qty, costUsd,
    priceUsd, txHash, ts: ts ?? Date.now(), status: "open",
  });
}

export async function openLots(wallet, symbol) {
  const { lots } = await cols();
  const q = { wallet: lc(wallet), status: "open", remaining: { $gt: 1e-12 } };
  if (symbol) q.symbol = symbol;
  return lots.find(q).sort({ ts: 1 }).toArray();
}

export async function positionQty(wallet, symbol) {
  const ls = await openLots(wallet, symbol);
  return ls.reduce((s, l) => s + l.remaining, 0);
}

/// FIFO-consume open lots; realize gain/loss vs the proceeds. Returns realized USD.
export async function recordSell({ wallet, symbol, qty: sellQty, proceedsUsd, priceUsd, txHash, ts }) {
  const { lots, realized } = await cols();
  const ls = await openLots(wallet, symbol);
  const pricePerUnit = proceedsUsd / sellQty;
  let rem = sellQty, realizedUsd = 0;
  const consumed = [];
  for (const lot of ls) {
    if (rem <= 1e-12) break;
    const c = Math.min(rem, lot.remaining);
    const costPerUnit = lot.costUsd / lot.qty;
    const gain = (pricePerUnit - costPerUnit) * c;
    realizedUsd += gain;
    const newRemaining = lot.remaining - c;
    await lots.updateOne(
      { _id: lot._id },
      { $set: { remaining: newRemaining, status: newRemaining <= 1e-9 ? "closed" : "open" } },
    );
    consumed.push({ txHash: lot.txHash, qty: c, costBasis: costPerUnit * c, gain });
    rem -= c;
  }
  await realized.insertOne({
    wallet: lc(wallet), symbol, sellQty, proceedsUsd, realizedUsd,
    txHash, ts: ts ?? Date.now(), consumed,
  });
  return { realizedUsd, consumed, unmatched: rem };
}

/// Portfolio snapshot: open positions (qty + avg basis) and realized P/L YTD.
export async function report(wallet) {
  const { realized } = await cols();
  const ls = await openLots(wallet, null);
  const bySym = {};
  for (const l of ls) {
    const s = (bySym[l.symbol] ??= { qty: 0, costUsd: 0 });
    s.qty += l.remaining;
    s.costUsd += (l.costUsd / l.qty) * l.remaining; // basis of the remaining qty
  }
  const rrows = await realized.find({ wallet: lc(wallet), ts: { $gte: yearStart() } }).sort({ ts: 1 }).toArray();
  const realizedYtd = rrows.reduce((s, r) => s + r.realizedUsd, 0);
  return { positions: bySym, realizedYtd, realizedRows: rrows };
}

export async function close() {
  if (_client) await _client.close();
  _client = _lots = _realized = null;
}
