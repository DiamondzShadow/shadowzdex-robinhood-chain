#!/usr/bin/env bash
#
# deploy-mainnet.sh — orchestrate the Robinhood Chain MAINNET (chain 4663) deploy
# in three confirmed steps:
#
#   1. router    deploy the production IntentRouter, register the CRE attestor,
#                set the fee policy, grant admin to the Safe (DeployProveMainnet)
#   2. venues    deploy the UniswapV2Adapter + register venues (DeployMainnetUniV2)
#   3. renounce  attach to the router from step 1 and drop the deployer's roles
#                so the Safe is the sole admin (DeployProveMainnet, RENOUNCE=true)
#
# Every step DRY-RUNS on a mainnet fork first, prints the result, and only
# broadcasts after you type 'yes'. Addresses come from ./.env.mainnet (gitignored)
# and are validated on-chain by the Solidity scripts themselves.
#
# Usage:
#   ./deploy-mainnet.sh            # run all three steps, confirming each
#   ./deploy-mainnet.sh router     # just step 1
#   ./deploy-mainnet.sh venues     # just step 2  (needs INTENT_ROUTER)
#   ./deploy-mainnet.sh renounce   # just step 3  (needs INTENT_ROUTER)
#
set -euo pipefail

cd "$(dirname "$0")"
ENV_FILE="./.env.mainnet"
RPC_ALIAS="rh_mainnet"
MRPC="https://rpc.mainnet.chain.robinhood.com"
CHAIN_ID=4663
MIN_ETH=0.002   # warn below this deployer balance

# ── styling ──
bold=$(tput bold 2>/dev/null || true); red=$(tput setaf 1 2>/dev/null || true)
grn=$(tput setaf 2 2>/dev/null || true); ylw=$(tput setaf 3 2>/dev/null || true)
rst=$(tput sgr0 2>/dev/null || true)
say()  { echo "${bold}==>${rst} $*"; }
ok()   { echo "${grn}  ✓${rst} $*"; }
warn() { echo "${ylw}  !${rst} $*"; }
die()  { echo "${red}  ✗ $*${rst}" >&2; exit 1; }

confirm() { # $1 = prompt; requires typing 'yes'
  local ans
  read -r -p "${bold}$1${rst} type 'yes' to proceed: " ans < /dev/tty
  [ "$ans" = "yes" ] || die "aborted."
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Update or append KEY=VALUE in the env file (used to persist INTENT_ROUTER).
persist_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# ── preflight ──
preflight() {
  need forge; need cast; need jq
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found — copy .env.mainnet.example to it and fill in verified addresses."

  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a

  : "${DEPLOYER_PK:?set DEPLOYER_PK in $ENV_FILE}"
  : "${ADMIN:?set ADMIN (mainnet Safe) in $ENV_FILE}"
  : "${ATTESTOR:?set ATTESTOR (CRE attestor pubkey) in $ENV_FILE}"
  case "$DEPLOYER_PK" in
    0x...|"" ) die "DEPLOYER_PK is still the placeholder — set a real key." ;;
    0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 )
      die "DEPLOYER_PK is the anvil test key — refusing to use it on mainnet." ;;
  esac

  local onchain; onchain=$(cast chain-id --rpc-url "$MRPC" 2>/dev/null || echo "?")
  [ "$onchain" = "$CHAIN_ID" ] || die "RPC chain-id is $onchain, expected $CHAIN_ID (Robinhood Chain mainnet)."

  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PK") || die "bad DEPLOYER_PK"
  local bal_wei bal_eth
  bal_wei=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$MRPC")
  bal_eth=$(cast from-wei "$bal_wei")
  [ "$(cast code "$ADMIN" --rpc-url "$MRPC" | wc -c)" -gt 3 ] || die "ADMIN ($ADMIN) has no code — must be the deployed Safe."

  say "Robinhood Chain mainnet (chain $CHAIN_ID)"
  ok "deployer  $DEPLOYER_ADDR  ($bal_eth ETH)"
  ok "Safe/ADMIN $ADMIN  (has code)"
  ok "attestor  $ATTESTOR"
  ok "permit2   ${PERMIT2:-<default canonical>}"
  [ -n "${INTENT_ROUTER:-}" ] && ok "router    $INTENT_ROUTER (existing)"
  awk "BEGIN{exit !($bal_eth < $MIN_ETH)}" && warn "deployer balance below ${MIN_ETH} ETH — top up before broadcasting."
  echo
}

# Run a Solidity script: dry-run on a fork, then confirm, then broadcast.
run_step() { # $1 = human name, $2 = script path
  local name="$1" path="$2"
  say "[$name] dry-run on a mainnet fork…"
  forge script "$path" --fork-url "$RPC_ALIAS" --sender "$DEPLOYER_ADDR" >/tmp/deploy_mainnet_sim.log 2>&1 \
    || { tail -30 /tmp/deploy_mainnet_sim.log; die "[$name] simulation failed — nothing broadcast."; }
  grep -q "Script ran successfully" /tmp/deploy_mainnet_sim.log || { tail -30 /tmp/deploy_mainnet_sim.log; die "[$name] simulation did not succeed."; }
  ok "[$name] simulation succeeded."
  confirm "[$name] BROADCAST to mainnet?"
  say "[$name] broadcasting…"
  forge script "$path" --rpc-url "$RPC_ALIAS" --broadcast --slow --private-key "$DEPLOYER_PK"
  ok "[$name] broadcast complete."
}

step_router() {
  say "STEP 1 — deploy IntentRouter + register attestor + hand admin to Safe"
  unset INTENT_ROUTER || true        # step 1 deploys fresh
  export RENOUNCE_DEPLOYER=false      # keep deployer CONFIG_ROLE for step 2
  run_step "router" script/DeployProveMainnet.s.sol
  local router
  router=$(jq -r '[.transactions[] | select(.contractName=="IntentRouter" and .transactionType=="CREATE")][0].contractAddress' \
    "broadcast/DeployProveMainnet.s.sol/${CHAIN_ID}/run-latest.json")
  [ -n "$router" ] && [ "$router" != "null" ] || die "could not read deployed router address from broadcast log."
  router=$(cast to-checksum-address "$router")
  persist_env INTENT_ROUTER "$router"
  export INTENT_ROUTER="$router"
  ok "IntentRouter deployed: ${bold}$router${rst} (saved to $ENV_FILE)"
  echo
}

step_venues() {
  say "STEP 2 — deploy UniswapV2Adapter + register venues"
  : "${INTENT_ROUTER:?INTENT_ROUTER not set — run step 1 first, or fill it in $ENV_FILE}"
  : "${V2_ROUTERS:?set V2_ROUTERS (comma-separated real routers) in $ENV_FILE}"
  : "${VENUE_KEYS:?set VENUE_KEYS in $ENV_FILE}"
  local IFS=,; for r in $V2_ROUTERS; do
    [ "$(cast code "$r" --rpc-url "$MRPC" | wc -c)" -gt 3 ] || die "V2 router $r has no code on mainnet."
  done
  ok "all V2 routers have code."
  run_step "venues" script/DeployMainnetUniV2.s.sol
  echo
}

step_renounce() {
  say "STEP 3 — renounce the deployer's roles (Safe becomes sole admin)"
  : "${INTENT_ROUTER:?INTENT_ROUTER not set — nothing to renounce}"
  warn "This is IRREVERSIBLE: the deployer $DEPLOYER_ADDR will no longer be able to configure the router."
  export RENOUNCE_DEPLOYER=true
  run_step "renounce" script/DeployProveMainnet.s.sol
  ok "deployer roles renounced — the Safe ($ADMIN) is now sole admin."
  echo
}

main() {
  local what="${1:-all}"
  preflight
  case "$what" in
    router)   step_router ;;
    venues)   step_venues ;;
    renounce) step_renounce ;;
    all)
      step_router
      step_venues
      confirm "Proceed to STEP 3 (renounce deployer)?"
      step_renounce
      ;;
    *) die "unknown step '$what' — use: all | router | venues | renounce" ;;
  esac
  say "${grn}done.${rst}"
}

main "$@"
