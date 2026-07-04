// Conditional-order store for the limit / stop-loss keeper, backed by the same
// MongoDB as the tax ledger. An order fires once when the Chainlink price crosses
// its trigger (direction "below" = price ≤ trigger, "above" = price ≥ trigger),
// then deactivates. rh_orders holds the standing orders; rh_order_fills is the log.

import { readFileSync } from "node:fs";
import { MongoClient } from "mongodb";
import { randomUUID } from "node:crypto";

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

let _client, _orders, _fills;
async function cols() {
  if (_orders) return { orders: _orders, fills: _fills };
  const env = loadMongoEnv();
  _client = new MongoClient(env.MONGO_URI, { serverSelectionTimeoutMS: 8000 });
  await _client.connect();
  const db = _client.db(env.MONGO_DB || "brmg_catalog");
  _orders = db.collection("rh_orders");
  _fills = db.collection("rh_order_fills");
  await _orders.createIndex({ active: 1, symbol: 1 });
  return { orders: _orders, fills: _fills };
}
const lc = (a) => String(a).toLowerCase();

export async function addOrder({ wallet, action, symbol, trigger, direction, usd, all, expiresAt }) {
  const { orders } = await cols();
  const doc = {
    sid: randomUUID().slice(0, 8), wallet: lc(wallet), action, symbol: String(symbol).toUpperCase(),
    trigger, direction, usd: usd ?? null, all: !!all, expiresAt: expiresAt ?? null,
    active: true, status: "open", createdAt: Date.now(), filledAt: null, txHashes: [], lastCheckPrice: null,
  };
  await orders.insertOne(doc);
  return doc;
}

export async function listOrders(wallet) {
  const { orders } = await cols();
  const q = wallet ? { wallet: lc(wallet) } : {};
  return orders.find(q).sort({ createdAt: 1 }).toArray();
}

export async function openOrders() {
  const { orders } = await cols();
  return orders.find({ active: true }).sort({ createdAt: 1 }).toArray();
}

export async function cancelOrder(sid) {
  const { orders } = await cols();
  const r = await orders.updateOne({ sid, active: true }, { $set: { active: false, status: "cancelled" } });
  return r.matchedCount > 0;
}

// Terminal resolution — status is "filled" | "expired" | "nofill". Logs a fill row.
export async function resolveOrder(sid, { status, txHashes = [], price = null, qty = 0 }) {
  const { orders, fills } = await cols();
  const doc = await orders.findOne({ sid });
  if (!doc) return;
  await orders.updateOne({ sid }, { $set: { active: false, status, filledAt: Date.now(), txHashes, lastCheckPrice: price } });
  await fills.insertOne({ sid, wallet: doc.wallet, action: doc.action, symbol: doc.symbol, trigger: doc.trigger, direction: doc.direction, status, price, qty, txHashes, ts: Date.now() });
}

export async function close() {
  if (_client) await _client.close();
  _client = _orders = _fills = null;
}
