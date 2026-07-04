// Best-execution router for the ShadowzDex co-pilot.
//
// The IntentRouter already routes by intent.venue → adapter, so ROUTING is
// solved on-chain. What was missing is the DECISION: quote every venue that
// lists a symbol, then either route the whole order to the best single venue
// or SPLIT it across venues to beat any single fill. This module is that
// decision layer — pure, view-only quoting; it never signs or sends.
//
// A venue quote mirrors ConstantProductAdapter.quote() exactly:
//   out = rOut * amtF / (rIn + amtF),  amtF = amountIn * (1 - fee)
// so the number we route on is the number the adapter will produce.

const poolAbi = [
  { name: "reserveUsdc", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "reserveStock", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "FEE_BPS", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
];
// Uniswap V2 pair — reserves ordered by token address (token0 < token1).
const univ2Abi = [
  { name: "getReserves", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint112" }, { type: "uint112" }, { type: "uint32" }] },
  { name: "token0", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
];

// x*y=k quote against local reserves — identical math to the on-chain adapter,
// so an off-chain search never disagrees with the fill.
function quoteLocal(res, tokenIn, amountIn) {
  if (amountIn <= 0n) return 0n;
  const [rIn, rOut] = tokenIn === "usdc" ? [res.rUsdc, res.rStock] : [res.rStock, res.rUsdc];
  const amtF = (amountIn * (10_000n - res.feeBps)) / 10_000n;
  const out = (rOut * amtF) / (rIn + amtF);
  return out < rOut ? out : 0n; // never drain the pool
}

// Snapshot every venue's reserves once (side = "usdc" means USDC is tokenIn / a buy).
// A venue's `kind` selects how reserves are read:
//   "cp"    — our ConstantProductAdapter (reserveUsdc/reserveStock/FEE_BPS)   [default]
//   "univ2" — a Uniswap V2-style pair (getReserves + token0), fee from cfg (30bps)
//             and `router` carried through so the co-pilot can build adapterData.
export async function loadVenues(pub, venuesCfg, usdcAddr) {
  return Promise.all(
    venuesCfg.map(async (v) => {
      const kind = v.kind ?? "cp";
      const base = { key: v.venue, label: v.label ?? v.venue, pool: v.pool, kind, router: v.router ?? null };
      if (kind === "univ2") {
        const [res, token0] = await Promise.all([
          pub.readContract({ address: v.pool, abi: univ2Abi, functionName: "getReserves" }),
          pub.readContract({ address: v.pool, abi: univ2Abi, functionName: "token0" }),
        ]);
        const usdcIsToken0 = !!usdcAddr && token0.toLowerCase() === usdcAddr.toLowerCase();
        return {
          ...base,
          rUsdc: usdcIsToken0 ? res[0] : res[1],
          rStock: usdcIsToken0 ? res[1] : res[0],
          feeBps: BigInt(v.feeBps ?? 30),
        };
      }
      const [rUsdc, rStock, feeBps] = await Promise.all([
        pub.readContract({ address: v.pool, abi: poolAbi, functionName: "reserveUsdc" }),
        pub.readContract({ address: v.pool, abi: poolAbi, functionName: "reserveStock" }),
        pub.readContract({ address: v.pool, abi: poolAbi, functionName: "FEE_BPS" }),
      ]);
      return { ...base, rUsdc, rStock, feeBps: BigInt(feeBps) };
    })
  );
}

// Build the router adapterData for one leg's venue. Constant-product pools take
// none ("0x"); Uniswap V2 venues encode (router, [tokenIn,tokenOut], feeOnTransfer)
// exactly as UniswapV2Adapter.execute() decodes it.
export function adapterDataFor(venue, tokenIn, tokenOut, encodeAbiParameters) {
  if (venue.kind === "univ2") {
    return encodeAbiParameters(
      [{ type: "address" }, { type: "address[]" }, { type: "bool" }],
      [venue.router, [tokenIn, tokenOut], false]
    );
  }
  return "0x";
}

// Quote each venue for the full order and sort best-first.
export function quoteAll(venues, side, amountIn) {
  return venues
    .map((v) => ({ ...v, out: quoteLocal(v, side, amountIn) }))
    .sort((a, b) => (a.out > b.out ? -1 : a.out < b.out ? 1 : 0));
}

// Optimal 2..n-way split that maximises total out. Constant-product marginal
// price is monotically increasing in fill size, so total-out(alloc) is concave
// in any pairwise transfer — a water-filling loop that repeatedly hands the next
// small slice to whichever venue currently offers the best marginal rate reaches
// the optimum. STEPS controls granularity (slice = amountIn / STEPS).
export function optimalSplit(venues, side, amountIn, steps = 200) {
  if (venues.length === 1) {
    const only = { ...venues[0], amountIn, out: quoteLocal(venues[0], side, amountIn) };
    return { allocations: [only], totalOut: only.out };
  }
  const slice = amountIn / BigInt(steps);
  if (slice === 0n) {
    // order smaller than one slice — just pick the single best
    const best = quoteAll(venues, side, amountIn)[0];
    return { allocations: [{ ...best, amountIn }], totalOut: best.out };
  }
  const alloc = venues.map((v) => ({ ...v, filled: 0n }));
  let remaining = amountIn;
  while (remaining > 0n) {
    const step = remaining < slice ? remaining : slice;
    // marginal out = out(filled+step) - out(filled) for each venue; give to the best.
    let bestI = 0, bestMarg = -1n;
    for (let i = 0; i < alloc.length; i++) {
      const cur = quoteLocal(alloc[i], side, alloc[i].filled);
      const nxt = quoteLocal(alloc[i], side, alloc[i].filled + step);
      const marg = nxt - cur;
      if (marg > bestMarg) { bestMarg = marg; bestI = i; }
    }
    alloc[bestI].filled += step;
    remaining -= step;
  }
  const allocations = alloc
    .filter((a) => a.filled > 0n)
    .map((a) => ({ key: a.key, label: a.label, pool: a.pool, amountIn: a.filled, out: quoteLocal(a, side, a.filled) }));
  const totalOut = allocations.reduce((s, a) => s + a.out, 0n);
  return { allocations, totalOut };
}

// Spot mid-price of a venue in USD/share (USDC 6-dec, stock 18-dec).
export function venueMid(v) {
  return v.rStock > 0n ? (Number(v.rUsdc) * 1e12) / Number(v.rStock) : 0;
}
function devBps(mid, oracle) {
  return oracle > 0 ? Math.round((Math.abs(mid - oracle) / oracle) * 10_000) : 0;
}

// The full best-execution decision for one order.
//   opts.oracle     — Chainlink USD/share price; enables the oracle filter
//   opts.maxDevBps  — drop any venue whose mid deviates more than this (default 500)
//   opts.minGainBps — only split when it beats the best single fill by this much
//
// returns { table, eligible, excluded, best, split, useSplit, improvementBps, naive, vsNaiveBps }
// where routing considers only `eligible` venues (in the oracle band); venues
// pushed out of band by the keeper are reported in `excluded` and never routed
// to — the same guard that makes the attestor refuse, now driving venue choice.
export function decide(venues, side, amountIn, { oracle = null, maxDevBps = 500, minGainBps = 5 } = {}) {
  const tagged = venues.map((v) => {
    const mid = venueMid(v);
    return { ...v, mid, devBps: oracle ? devBps(mid, oracle) : 0 };
  });
  const eligible = oracle ? tagged.filter((v) => v.devBps <= maxDevBps) : tagged;
  const excluded = oracle ? tagged.filter((v) => v.devBps > maxDevBps) : [];
  if (!eligible.length) {
    return { table: [], eligible, excluded, best: null, split: { allocations: [], totalOut: 0n }, useSplit: false, improvementBps: 0, naive: null, vsNaiveBps: 0 };
  }

  const table = quoteAll(eligible, side, amountIn);
  const best = table[0];
  const split = optimalSplit(eligible, side, amountIn);
  const gain = split.totalOut - best.out;
  const improvementBps = best.out > 0n ? Number((gain * 10_000n) / best.out) : 0;
  const multiLeg = split.allocations.length > 1;
  const useSplit = multiLeg && improvementBps >= minGainBps;
  // vs the naive Phase-1 default (first configured venue = <SYM>_MKT), if eligible
  const naive = table.find((t) => t.key.endsWith("_MKT")) ?? table[table.length - 1];
  const vsNaiveBps = naive && naive.out > 0n ? Number(((best.out - naive.out) * 10_000n) / naive.out) : 0;
  return { table, eligible, excluded, best, split, useSplit, improvementBps, naive, vsNaiveBps };
}
