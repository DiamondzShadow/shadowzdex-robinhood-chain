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

**Chainlink on Robinhood Chain** — Data Feeds (equity reference prices incl.
NVDA/GOOG/AAPL), Data Streams, and CCIP are the chain's official oracle layer from
block zero. Next hardening step: the attestor verifies each quote against the
Chainlink equity feed before signing, so every fill is oracle-checked.

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
