# ShadowzDex on Robinhood Chain — Phase 0

**Prove that a ShadowzDex attestor-signed intent routes through the `IntentRouter`
and fills against a Stock-Token pool on Robinhood Chain.**

Robinhood Chain (Arbitrum Orbit, EVM, chain id `46630` testnet / `4663` mainnet)
launched with spot Stock Tokens and two AMMs — but **no intent-based aggregator
or best-execution layer**. ShadowzDex already runs exactly that on Arbitrum. This
repo is the first, smallest deployable proof that our stack drops onto the new
chain unchanged.

> **Status:** ✅ **LIVE on Robinhood Chain testnet (chain `46630`).** A signed
> intent filled `100 USDC → 0.5 tNVDA` on-chain — verified: the buyer's
> Stock-Token balance reads `0.5e18`. See [Live deployment](#live-deployment).

## Live deployment

Deployed + proven on Robinhood Chain testnet (chain `46630`) on 2026-07-03.
Explorer: https://explorer.testnet.chain.robinhood.com

| Contract | Address |
|---|---|
| **IntentRouter** | [`0xec00f9cf9483065d888049af0ef546f1aac59087`](https://explorer.testnet.chain.robinhood.com/address/0xec00f9cf9483065d888049af0ef546f1aac59087) |
| FixedRatePoolAdapter (test venue) | [`0xbaf09a8736395492ec232f083081feb2a0fe2dc2`](https://explorer.testnet.chain.robinhood.com/address/0xbaf09a8736395492ec232f083081feb2a0fe2dc2) |
| USDC (mock, 6-dec) | `0xf9bb9944ae132cd0eb94c021920c122d26ce88cd` |
| tNVDA — Stock Token (mock, 18-dec) | `0x900d189955e05e6a7b8f23df86a1cad86920f4b2` |

**Fill tx:** [`0x66e9376cf66f374f06be4a9856e9f8e7b570da5589c87b8b425d02db60079b35`](https://explorer.testnet.chain.robinhood.com/tx/0x66e9376cf66f374f06be4a9856e9f8e7b570da5589c87b8b425d02db60079b35)
— `IntentRouter.executeSwap` → `100 USDC` in, `0.5 tNVDA` out, `minOut` enforced.

### Phase 1 — real Stock Tokens listed on ShadowzDex

Faucet Stock Tokens now trade through the **same** `IntentRouter` via real
constant-product pools (`ConstantProductAdapter`, 0.30% fee, genuine slippage).
A live buy of **100 USDC → ~0.312 TSLA** filled and moved the curve (post-trade
quote fell to 0.275 TSLA/100 USDC).

| Market | Pool (adapter) | Stock Token |
|---|---|---|
| TSLA / USDC | `0x24014a267D5CfA33e2D8d57082Da2657a304f83F` | `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E` |
| AMD / USDC | `0x54421fdcC9Ec50867D24367201bEEDc232C25998` | `0x71178BAc73cBeb415514eB542a8995b82669778d` |
| AMZN / USDC | `0x09ccA9757B350a10A7B0346b42C8b7d027ac80Ed` | `0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02` |

Adding a market is one call — deploy a `ConstantProductAdapter`, seed it, and
`router.setVenue(keccak256("<SYM>_MKT"), pool, false)`. NFLX, PLTR, wGOLD, wETH,
wBTC (all faucet-available) drop in the same way. Run: `script/ListStocks.s.sol`.

### Best-execution routing — the aggregator, live (`copilot/bestex.mjs`)

Phase 1 listed **one** pool per stock. An aggregator needs a *choice*. This gives
every market a **second, independently-priced venue** and puts a real
best-execution router in front of them: quote every venue, drop any that fail the
Chainlink guard, then route the whole order to the best single fill **or split it
across venues** when that beats any single pool. The `IntentRouter` already routes
by `intent.venue → adapter`, so routing was solved on-chain — this is the missing
*decision* layer, and it's identical to the 1inch/CoW model, intent-based.

Second venue per market (`script/AddVenues.s.sol`), registered on the **live**
Phase-0 router — deeper reserves, so the winning venue is **trade-size-dependent**:

| Market | Pool A (`<SYM>_MKT`) | Pool B (`<SYM>_B`, deeper) |
|---|---|---|
| TSLA | `0x24014a267D5CfA33e2D8d57082Da2657a304f83F` | `0x56b143e0b17a8252bad72be2bca4fbfa0f3bfd7d` |
| AMD  | `0x54421fdcC9Ec50867D24367201bEEDc232C25998` | `0xb7f74b12aa195ddc7f294cd1c2422fcef725add0` |
| AMZN | `0x09ccA9757B350a10A7B0346b42C8b7d027ac80Ed` | `0xe4dd21ec906c99ab94ba296a37d1e1a61d6a9885` |

The router (`decide()` in `bestex.mjs`) does three things, all view-only and using
the **exact** constant-product math the adapter executes, so the number it routes
on is the number the fill produces:

1. **Oracle-filtered venue set** — a venue whose spot deviates > 5% from the
   Chainlink feed is dropped *from routing* (not just refused at sign time). The
   same guard that protects the attestor now drives venue choice, so a pool the
   testnet keeper has let drift is simply skipped in favour of the healthy one.
2. **Best single fill** — route the whole order to the venue with the most output
   (deeper Pool B wins large orders; a keener-priced Pool A can win small ones).
3. **Optimal split** — a water-filling search hands each marginal slice to the
   venue offering the best marginal rate, then executes the plan as N
   attestor-signed intents. It's only taken when it beats the best single fill.

**Proven live on Robinhood Chain testnet (chain `46630`):**

- On-chain best-ex proof — a 1,000-USDC TSLA buy quotes higher on deep Pool B and
  routes there: [`0x9c654475…3ed6`](https://explorer.testnet.chain.robinhood.com/tx/0x9c65447536e3b6b4ae02d488ffea8994f037139326ff77b8fddb98ad77cd3ed6).
- Co-pilot **split** fill — `"buy $300 of TSLA"` split `$115.50 → Pool A` +
  `$184.50 → Pool B`, delivering `0.7616 TSLA` vs `0.7322` best-single (**+400bps**)
  across two attestor-signed intents:
  [`0x882f08b9…5264e`](https://explorer.testnet.chain.robinhood.com/tx/0x882f08b9a2b2b61d6bac0afdb3e24043c7908cbecd02db897d3b648980d5264e)
  · [`0x836daeb5…6acd`](https://explorer.testnet.chain.robinhood.com/tx/0x836daeb5acecd4ab5e7865d5ff715350133d8730a1aa5f417599ac0150ac6acd).

```bash
node copilot/copilot.mjs "buy $300 of TSLA"   # quotes both venues, splits, fills
node copilot/rebalance.mjs                     # walk pools back to the oracle price
```

> **Testnet honesty.** These two pools are independent constant-product AMMs
> standing in for the chain's real venues (Uniswap + Pleiades) — our faucet Stock
> Tokens have no pools there yet. The router is venue-agnostic (it only needs an
> `IVenueAdapter` that can `quote`), so on mainnet a `UniswapV2Adapter` /
> `PleiadesAdapter` drops in unchanged and the same `decide()` routes across them.
> Reserves are small, so keep trades modest or run `rebalance.mjs`; the testnet
> Chainlink stand-in feeds are set once and don't actively track, so a large fill
> can push a pool out of band until you rebalance — which the router handles by
> routing to the other venue.

### Mainnet venue — real Uniswap V2 routing (`UniswapV2Adapter`)

The `ConstantProductAdapter` pools above are our own seeded testnet liquidity. On
mainnet the router routes through the **chain's real venues** — Robinhood Chain
ships Uniswap V2 + Pleiades, both V2-style AMMs — via `UniswapV2Adapter`
(`src/shadowz/adapters/UniswapV2Adapter.sol`), vendored from the ShadowzDex
production `SushiV2Adapter` (live on Arbitrum), logic unchanged.

One adapter serves **every** V2 pair. It decodes `adapterData` and calls the
router directly, so it reaches brand-new, unindexed pools in a single tx:

```
adapterData = abi.encode(address v2Router, address[] path, bool feeOnTransfer)
  • v2Router   — governance-whitelisted (allowedRouter); the attestor picks
                 Uniswap / Pleiades / Sushi by where the pool lives
  • path       — [tokenIn, …, tokenOut]; head/tail checked against the intent
  • minOut     — enforced by the IntentRouter after execute() returns
```

**Proven live on Robinhood Chain testnet** — the adapter registered on the **live**
Phase-0 router and an attestor-signed intent filled `100 USDC → tUNIV2` through a
Uniswap-V2 pool (a `MockUniswapV2` stand-in, since our faucet Stock Tokens have no
real V2 pairs on testnet). The script asserts the on-chain fill **exactly equals**
the off-chain V2 quote:

| Contract | Address |
|---|---|
| UniswapV2Adapter | `0x8f929a410408d18b04da787ea596afbdbc4e0e55` |
| venue key | `keccak256("UNISWAP_V2")` |
| Fill tx | [`0x93b2f143…b80e`](https://explorer.testnet.chain.robinhood.com/tx/0x93b2f14318b15176eaafeb35785ff7f82deb5a42f1e973b9d4beb5ebf5b1b80e) — `got == expOut`, `got >= minOut` |

Run: `forge script script/ProveUniV2.s.sol --rpc-url rh_testnet --broadcast --slow`.

The best-execution router treats a V2 venue like any other — it quotes the pair's
`getReserves()` with the exact Uniswap `getAmountOut` math (bit-identical to the
on-chain fill) and can route or split across constant-product **and** V2 venues in
the same order. A market lists a V2 venue by adding to `markets.json`:

```jsonc
{ "venue": "UNISWAP_V2", "pool": "<pair addr>", "kind": "univ2",
  "router": "<v2 router addr>", "feeBps": 30, "label": "Uniswap V2" }
```

**Mainnet deploy — full stack, in sequence** (`rh_mainnet` =
`rpc.mainnet.chain.robinhood.com`, chain `4663`). Every address comes from env
(`.env.mainnet.example`); both scripts validate on-chain before any write.

1. **Router** — `script/DeployProveMainnet.s.sol` deploys the production
   `IntentRouter`, authorizes the CRE attestor, sets the fee policy, and grants
   every admin role to the mainnet Safe (`ADMIN` must have code; a Gnosis Safe's
   `getThreshold()` is sanity-checked). `PERMIT2` defaults to the canonical
   `0x0000…78BA3` — **verified deployed on RH mainnet**, so the Permit2 path works
   out of the box. Keep `RENOUNCE_DEPLOYER=false` so step 2 can use the deployer's
   `CONFIG_ROLE`; the run asserts the attestor is registered and the Safe holds
   admin. Copy the emitted router address into `INTENT_ROUTER`.
2. **Adapter + venues** — `script/DeployMainnetUniV2.s.sol` (below).
3. **Renounce** — re-run step 1 with `RENOUNCE_DEPLOYER=true` (or renounce via the
   Safe) to drop the deployer's roles once wiring is done. The run asserts the
   deployer no longer holds admin.

```bash
cp .env.mainnet.example .env.mainnet    # fill in verified mainnet addresses
forge script script/DeployProveMainnet.s.sol --fork-url rh_mainnet -vvvv          # dry-run step 1
forge script script/DeployProveMainnet.s.sol --rpc-url rh_mainnet --broadcast --slow
```

**Step 2 — wire the Uniswap V2 venue** with `script/DeployMainnetUniV2.s.sol`
against the router from step 1. Every address is **validated on-chain before any
write**:

- `INTENT_ROUTER` must have code, and the broadcaster must hold its `CONFIG_ROLE`
  (fails fast with `MissingConfigRole` instead of a bare `setVenue` revert);
- every `V2_ROUTERS` entry must have code **and** answer `factory() != 0` — i.e.
  actually be a Uniswap-V2 router, so a fat-fingered address reverts `NotARouter`
  rather than mis-wiring the live router;
- `ADMIN` (the adapter's role admin — the per-chain Safe) must be nonzero.

It deploys the adapter with the real routers whitelisted and registers one venue
key per DEX (`VENUE_KEYS=UNISWAP_V2,RIALTO_V2`) — all resolving to the single
adapter; the pool is chosen by `adapterData`. Then point each market's `univ2`
venue in `markets.json` at the real pair — no co-pilot code changes.

```bash
forge script script/DeployMainnetUniV2.s.sol --fork-url rh_mainnet -vvvv        # dry-run step 2
forge script script/DeployMainnetUniV2.s.sol --rpc-url rh_mainnet --broadcast --slow
```

> The real Uniswap / Rialto router addresses weren't public at time of writing
> (mainnet launched 2026-07) — get them from `docs.robinhood.com/chain/connecting`,
> the mainnet explorer, Uniswap's deployment docs, or `chain-developers-group@robinhood.com`,
> and the script's on-chain validation guarantees you can't wire a wrong one.

### Co-pilot — natural-language trading (`copilot/`)

The flagship: say what you want, it fills. Fireworks parses the instruction, the
attestor signs the intent, and the router executes it against the live markets.

```bash
cd copilot && npm install
node copilot.mjs "buy $50 of AMD"
# → parsed · quoted · attestor-signed · executeSwap · ✅ 0.3116 AMD in your wallet
```

Live example: [`0xda9ba38e…5288`](https://explorer.testnet.chain.robinhood.com/tx/0xda9ba38e6c7b11d97be8439c538c7b5c2370cc323e96af93ddf146ea58305288)
— "buy $50 of AMD" → on-chain fill on Robinhood Chain testnet. Keys are read from
`../.env` (git-ignored); nothing is hardcoded.

### Tax-aware co-pilot (the differentiator)

A **MongoDB tax-lot ledger** (`copilot/ledger.mjs`) sits under the co-pilot. Every
buy opens a lot with cost basis; every sell consumes lots **FIFO** and realizes
gain/loss; positions are **marked to the Chainlink oracle**; and "harvest"
sells positions trading below basis to book the loss. A `report` prints
open positions + realized P/L (YTD) as Form-8949-style rows.

```bash
node copilot.mjs "buy $60 of TSLA"     # opens a lot (basis tracked)
node copilot.mjs "show my taxes"        # positions marked to Chainlink + realized P/L
node copilot.mjs "harvest my losses"    # sells only positions below basis
```

Nobody onchain does tax-aware trading — and it speaks straight to Robinhood's
retail base. Lots live in Atlas (`rh_tax_lots` / `rh_tax_realized`).

### Web chat UI (`copilot/server.mjs` + `copilot/public/`)

A browser front-end for the co-pilot — type in plain English, watch each step
stream in (parse → Chainlink check → attestor sign → fill).

```bash
cd copilot && node server.mjs      # → http://127.0.0.1:8799
```

Keys stay on the server; the browser only sends text and receives log lines
(SSE). Proven live: "show my taxes" streams the tax report, "buy $30 of AMZN"
executes an oracle-checked, attestor-signed fill on-chain — both from the browser.

> **Security:** binds to `127.0.0.1` and can move (testnet) funds. Don't expose
> publicly without auth / per-user wallets — demo locally or over an SSH tunnel.

### Oracle-verified attestor (Chainlink)

The attestor won't sign a mispriced pool. Before signing, it reads the pool's spot
price and the **Chainlink equity feed** (`AggregatorV3Interface`) and refuses if
they deviate beyond `oracleMaxDevBps` (default 500 = 5%).

```
🔗 Chainlink AMZN/USD $200.00 · pool spot $200.00 · dev 0bps  → signs ✓
🔗 Chainlink AMZN/USD $400.00 · pool spot $227.51 · dev 4312bps → 🔒 REFUSES to sign
```

Both paths proven live on testnet (the feed was set to $400 to force the reject,
then reset). Chainlink is Robinhood Chain's **official** oracle from block zero
(Data Feeds / Data Streams / CCIP), so on mainnet the `feed` address in
`markets.json` becomes the real Chainlink equity feed — the co-pilot code is
unchanged. Testnet feeds here are `AggregatorV3Interface`-compatible stand-ins
(`MockAggregator`), deployed by `script/DeployFeeds.s.sol`.

| Feed | Address (testnet) | Price |
|---|---|---|
| TSLA/USD | `0xb171be80e24e1084089a8b6fd839151aa8804816` | $300 |
| AMD/USD | `0xd3db2eb0a6660fc4bb1a481043477c52b8b01510` | $150 |
| AMZN/USD | `0xa241946718dd761b006e68a0aa53d028580e383e` | $200 |

---

## What it proves

```
attestor signs SwapIntent (EIP-712, domain = this router, chainId 46630)
        │
        ▼
user ──USDC──▶ IntentRouter.executeSwap(intent, sig, adapterData)
                 │  verifies attestor sig + nonce + deadline (QuoteVerifier)
                 │  transfers USDC ─▶ venue adapter
                 ▼
           FixedRatePoolAdapter ──tNVDA──▶ router ──▶ user
                 │  (a stand-in Stock-Token pool)
                 ▼
           minOut enforced, SwapExecuted emitted
```

The simulation deploys the **real** `IntentRouter` + `QuoteVerifier` (vendored
verbatim from ShadowzDex), registers a venue, signs an intent with `vm.sign`, and
asserts the fill:

| In | Out | Check |
|----|-----|-------|
| `100 USDC` (6-dec) | `0.5 tNVDA` (18-dec) @ `$200` | `got == reported == 0.5e18`, `got >= minOut` |

Estimated gas for the whole deploy-and-fill: **~0.000118 ETH**.

---

## Repo layout

```
src/shadowz/        IntentRouter, QuoteVerifier, FeeVault, interfaces
                    — vendored verbatim from DiamondzShadow/ShadowzDex (audited path)
src/kit/            MockERC20 (USDC / Stock-Token stand-ins)
                    FixedRatePoolAdapter (IVenueAdapter — TEST-ONLY, fixed price)
script/DeployProve  deploy + sign + fill + assert, in one run
```

## Quickstart

```bash
# 1. gas-free simulation against a RH Chain testnet fork (real chainId 46630 domain)
forge script script/DeployProve.s.sol --fork-url rh_testnet -vvvv

# 2. live broadcast (needs the deployer funded — see Faucet)
cp .env.example .env      # set DEPLOYER_PK + ATTESTOR_PK
forge script script/DeployProve.s.sol --rpc-url rh_testnet --broadcast \
  --private-key $DEPLOYER_PK
```

### Network
| | value |
|---|---|
| Testnet RPC | `https://rpc.testnet.chain.robinhood.com` (wired as `rh_testnet`) |
| Chain ID | `46630` |
| Explorer | https://explorer.testnet.chain.robinhood.com |
| Faucet | https://faucet.testnet.chain.robinhood.com — 0.05 ETH + Stock Tokens / 24h |

**The only manual step:** claim testnet ETH from the faucet to the deployer
address, then run step 2. The faucet also dispenses real testnet Stock Tokens,
which replace `FixedRatePoolAdapter` with a live pool in Phase 1.

---

## Security posture

Built to the standard the hackathon (and real funds) demand:

- **No secrets in git.** `.env`, `cache/`, and `broadcast/` are git-ignored — note
  that Foundry writes resolved private keys into `cache/**/run-latest.json`, so
  that path is excluded explicitly. Keys come from env only; `.env.example` ships
  placeholders.
- **Audited core, unchanged.** `IntentRouter` / `QuoteVerifier` are vendored
  verbatim from ShadowzDex (live on Arbitrum) — attestor-signature verification,
  per-user nonce replay guard, deadline expiry, and slippage (`minOut`) are the
  same reviewed code, not a reimplementation. OpenZeppelin v5 for AccessControl /
  EIP-712 / ECDSA / SafeERC20.
- **Test-only clearly labeled.** `FixedRatePoolAdapter` has a fixed price and no
  oracle — it exists solely to prove the pipeline and is **not** for mainnet. Real
  venues use `DodoAdapter` / `V4SwapAdapter` against live pools with attestor
  quotes sanity-checked by Chainlink feeds.
- **Least privilege by default.** Permit2 disabled (zero address) unless wired;
  `sdmToken` unset disables tier logic on testnet; `feeBps` starts at 0.
- **Reproducible.** Pinned solc `0.8.24`, deterministic build.

---

## How ShadowzDex is positioned on Robinhood Chain

We do **not** compete with Uniswap or Pleiades (the chain's liquidity venues). We
sit **above** them:

- **The best-execution / intent layer the chain lacks** — one attestor-signed,
  gasless intent, routed to the best fill across Uniswap + Pleiades + our own
  pools. The 1inch/CoW of Robinhood Chain, but intent-based.
- **The agentic front-end** — our AI co-pilot turns natural language into these
  intents, so the router is the execution spine under a tax-aware trading agent.

Complements the ecosystem, captures the routing layer. See the ecosystem strategy
brief for the full plan.

---

## Provenance

`src/shadowz/**` is copied from [`DiamondzShadow/ShadowzDex`](https://github.com/DiamondzShadow/ShadowzDex)
at the current `IntentRouter` revision. In a productionized repo these become a git
submodule or an npm package to keep a single source of truth.
