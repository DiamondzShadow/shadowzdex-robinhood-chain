// Schedule store for the DCA keeper, backed by the same MongoDB as the tax ledger.
// A schedule is a standing "buy $X of SYM every N" order; the keeper (dca.mjs)
// fires the ones that are due. rh_dca_schedules holds the standing orders;
// rh_dca_runs is the append-only execution log.

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

let _client, _sched, _runs;
async function cols() {
  if (_sched) return { sched: _sched, runs: _runs };
  const env = loadMongoEnv();
  _client = new MongoClient(env.MONGO_URI, { serverSelectionTimeoutMS: 8000 });
  await _client.connect();
  const db = _client.db(env.MONGO_DB || "brmg_catalog");
  _sched = db.collection("rh_dca_schedules");
  _runs = db.collection("rh_dca_runs");
  await _sched.createIndex({ active: 1, nextRunAt: 1 });
  return { sched: _sched, runs: _runs };
}
const lc = (a) => String(a).toLowerCase();

export async function addSchedule({ wallet, symbol, usd, intervalSec, intervalLabel, maxRuns, budgetUsd, firstRunAt }) {
  const { sched } = await cols();
  const doc = {
    sid: randomUUID().slice(0, 8), wallet: lc(wallet), symbol: String(symbol).toUpperCase(),
    usd, intervalSec, intervalLabel, maxRuns: maxRuns ?? null, budgetUsd: budgetUsd ?? null,
    nextRunAt: firstRunAt ?? Date.now(), active: true, createdAt: Date.now(),
    runs: 0, spentUsd: 0, lastRunAt: null, lastError: null,
  };
  await sched.insertOne(doc);
  return doc;
}

export async function listSchedules(wallet) {
  const { sched } = await cols();
  const q = wallet ? { wallet: lc(wallet) } : {};
  return sched.find(q).sort({ createdAt: 1 }).toArray();
}

export async function dueSchedules(now = Date.now()) {
  const { sched } = await cols();
  return sched.find({ active: true, nextRunAt: { $lte: now } }).sort({ nextRunAt: 1 }).toArray();
}

export async function cancelSchedule(sid) {
  const { sched } = await cols();
  const r = await sched.updateOne({ sid }, { $set: { active: false } });
  return r.matchedCount > 0;
}

// Record one keeper execution; advance nextRunAt; auto-deactivate on cap reached.
export async function recordRun(sid, { ok, nextRunAt, spentDelta = 0, txHashes = [], qty = 0, error = null }) {
  const { sched, runs } = await cols();
  const doc = await sched.findOne({ sid });
  if (!doc) return null;
  const update = { $set: { nextRunAt, lastRunAt: Date.now(), lastError: error } };
  if (ok) update.$inc = { runs: 1, spentUsd: spentDelta };
  await sched.updateOne({ sid }, update);
  await runs.insertOne({ sid, wallet: doc.wallet, symbol: doc.symbol, ts: Date.now(), ok, spentUsd: spentDelta, qty, txHashes, error });

  const fresh = await sched.findOne({ sid });
  const hitMax = fresh.maxRuns != null && fresh.runs >= fresh.maxRuns;
  const hitBudget = fresh.budgetUsd != null && fresh.spentUsd >= fresh.budgetUsd - 1e-9;
  if (hitMax || hitBudget) await sched.updateOne({ sid }, { $set: { active: false } });
  return { deactivated: hitMax || hitBudget, hitMax, hitBudget };
}

export async function close() {
  if (_client) await _client.close();
  _client = _sched = _runs = null;
}
