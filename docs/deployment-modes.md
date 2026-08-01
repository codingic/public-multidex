# Deployment modes — dev / play / production

One compile-time switch in `src/backend/main.mo` decides the exchange's
posture:

```motoko
public type DeployMode = { #dev; #play; #production };
transient let DEPLOY_MODE : DeployMode = #dev;   // ← flip per target, then build
```

`transient` is load-bearing: a top-level `let` in a persistent actor is
implicitly stable, so without it an upgraded canister would silently keep the
OLD posture baked into its stable memory. The two legacy flags are now derived
(`IS_PRODUCTION = DEPLOY_MODE == #production`, `IS_DEV = DEPLOY_MODE == #dev`)
so every pre-existing `IS_PRODUCTION` gate keeps its meaning.

The frontend reads the posture at startup via the public
`getDeployMode() : query → "dev" | "play" | "production"` and adapts the
on-ramp button (dev: open faucet modal · play: 🎁 Claim Starter Pack ·
production: hidden — deposits go via the Bridge).

## Why three postures

MULTI/DEX first ships as a **play-money competition** on a cloud engine:
community members mint one fixed dummy basket and trade for leaderboard
places. That target is neither dev (players must NOT get price overrides or
an unlimited faucet — leaderboard fairness) nor production (no Bridge, no
real assets, engines can't call the NNS subnet yet, and players still need
SOME on-ramp). Overloading `IS_PRODUCTION` for it would either leave dev
hooks alive in public or kill the only on-ramp. Hence a first-class third
posture.

## Kill matrix

| Surface | #dev | #play | #production | Why |
| --- | --- | --- | --- | --- |
| `addTestTokens` (open user faucet) | ✅ | ❌ | ❌ | play users get ONE basket, not unlimited mints |
| `claimPlayFunds` (one-shot starter basket) | ✅ | ✅ | ❌ | the play on-ramp; testable in dev; production deposits via Bridge |
| `setAmmRefPrice` (manual mark override) | ✅ | ❌ | ❌ | an operator must not move the mark by hand where scores/value ride on it |
| `setTestScorecard`, `setTestShedFloor`, `setTestPendingJump`, `setTestMinSources`, `setTestXrcRate` (behavior/price hooks) | ✅ | ❌ | ❌ | test-determinism hooks; fairness/manipulation surface elsewhere |
| `debugInspectByUsername` | ✅ | ❌ | ❌ | privacy — operator shouldn't read arbitrary accounts in public deployments |
| `setTestBalance` / `bulkSetTestBalances` / `getTestBalance` (AdminOps, controller-only) | ✅ | ✅ | ❌ | operator bootstrap (vault seeding, sim wallets) still needed on play; every delta lands in `extNetFlow`, so it reads as CAPITAL, never as leaderboard profit |
| `setTestTimersPaused` | ✅ | ✅ | ✅ | controller-only emergency brake, deliberately ungated |
| `resetExchange`, `requoteAmm`, `fetchAndSetRefPrice`, `seedAmmPool` | ✅ | ✅ | ✅ | controller-only ops surface (season resets on play use `resetExchange`) |
| `setXrcCanister` / `adminRefreshXrcAnchors` | ✅ | ✅ | ✅ | controller-only oracle wiring (see below) |
| inspect: unknown-principal update calls | ✅ | ✅ | ❌ | a play user's FIRST call is `claimPlayFunds` — they can't be registered before it; production keeps the strict gate (registration happens off-ingress via the Bridge's `creditAndRegister`) |

## claimPlayFunds semantics

- One claim per principal for the **deployment's lifetime** — the claim
  ledger (`playClaims`) is deliberately NOT cleared by `resetExchange`, so a
  season reset (which keeps wallets and re-baselines the leaderboard) cannot
  be farmed for fresh baskets. A truly fresh season = reinstall.
- Each basket leg is recorded via `appendDeposit` → deposit history + the
  leaderboard's `extNetFlow` capital baseline: a claim is capital, never
  profit (pinned by `tests/test_play_claim.sh`).
- The claim also registers the caller (the inspect gate's precondition) and
  mints the join badge.
- Basket (`PLAY_BASKET`): $10,000 ICPUSD · 0.1 BTC · 1 ETH · 10 SOL · 500 ICP.

## Oracle wiring per posture

The XRC fallback anchor loop (docs/oracle-xrc-fallback-design.md) runs only
when a controller has wired a principal via `setXrcCanister` (stable — it
survives upgrades but must be re-applied after a REINSTALL, same as
`setBridge`):

- **dev**: wire the local `xrc-mock` canister (cold_start does this) — the
  real call path (cycles attach, candid decode, decimals→e8) is exercised
  locally.
- **play (cloud engine)**: leave UNWIRED while engines cannot call the NNS
  subnet — the loop no-ops, the primary 3-provider HTTPS feed carries
  pricing, and a primary outage degrades to fail-stalled (frozen mark, AMM
  pauses at the 5-min staleness wall) exactly as designed. Wire it the day
  engines get NNS reach.
- **production**: wire the real XRC `uf6dk-hyaaa-aaaaq-qaaaq-cai` and smoke
  with `adminRefreshXrcAnchors()` + `getXrcAnchors()`.

## Flipping a target (deploy-time checklist)

1. Edit `DEPLOY_MODE` in `src/backend/main.mo`; build + deploy.
2. `getDeployMode` returns the intended posture (frontend adapts on reload).
3. Posture smoke, non-dev targets:
   - `addTestTokens` is a silent no-op (balance unchanged);
   - `setAmmRefPrice` → `#err("setAmmRefPrice is a dev-only override")`;
   - `setTestScorecard` → dev-only error; other hooks silently no-op.
4. **play** additionally: `claimPlayFunds` from a fresh principal → basket
   lands, second claim refused; leaderboard shows the claim as capital.
5. **production** additionally: `claimPlayFunds` → refused ("deposit real
   assets via the Bridge"); Bridge wired (`setBridge`); XRC wired
   (`setXrcCanister`) + anchor smoke.
6. NEVER deploy `xrc-mock` to a value-bearing or public target (its `setRate`
   is open by design).

## Upgrade & persistence invariants

The backend is a `persistent actor` built with `--default-persistent-actors`,
so **every top-level declaration is stable unless marked `transient`**.
`transient` is therefore not a performance hint — it means *"reset to the
initializer on every upgrade"*. Getting this wrong is silent: no error, no
log, just state that quietly reverts each deploy.

**`transient` is correct for** derived caches that recompute themselves
(memoised principals, log edge-trigger flags), heartbeat schedule stamps that
self-heal on the next beat, dev/test pins (fail-safe: they evaporate on a real
deploy), telemetry counters, and closures/actor refs (function values cannot be
stable).

**`transient` is WRONG for** anything an operator sets once and expects to
stick, any accumulator that bounds spending over a window, and any
idempotency/dedup state. Two real incidents:

- `_ammAutoInventory` was `transient`, and the only thing that sets it true is
  the *seeding* block (`deploy.sh` / `play_start.sh` / `seed.sh`), which an
  update deploy skips. So every wasm deploy silently disabled AMM inventory
  derivation — found `false` on the live subnet on 2026-07-25, changing quoted
  depth and LP exposure with no log line. Fixed by dropping `transient`.
- `_arbHourUsd` / `_arbHourStartNs` (the arbitrageur's hourly loss cap) and
  `_fuelCooldownUntil` (the auto-fuel throttle) had the same shape: each
  upgrade handed back a full budget on top of whatever was already spent.

**No post-upgrade index rebuild (2026-07-25).** `ensureInit` used to call
`OrderBook.rebuildIndexes`. It was removed because it was both redundant and
dangerous:

- *Redundant* — every index inside `OrderStore` is stable (`OrderBook.mo`
  declares nothing `transient`), so the rebuild cleared nine live maps and
  reconstructed them identically. The old "run once after upgrade" comment
  was a fossil from classic persistence, where rebuilding after
  deserialization genuinely was required.
- *Dangerous* — it ran on the first **update call** after an upgrade, not in
  an upgrade hook. So the upgrade succeeded and the first user to call paid
  O(open orders + retained trades) in one message, and the done-flag latched
  only *after* the rebuild returned. Exceeding the instruction limit would
  trap that call, never latch, and trap again on every subsequent update call
  — a permanent update-path brick while queries kept answering (so monitoring
  reads healthy). Compare an upgrade-hook failure, which fails *closed*: the
  upgrade is rejected and the canister keeps running the old code.
- It also corrupted the 24h rolling stats: `rollingStats[m].cursor` is a
  *position* in `orderStore.tradesByMarket[m]`, and the rebuild re-derived
  that list from the global trades list, which has a different trim history.

Repair is now the controller-only `adminRebuildIndexes()` (it also runs
`verifyAggregates` and reports the outcome). Verified on 2026-07-25 by
seeding a book, upgrading the wasm in place, and confirming the book was
byte-identical with aggregates clean on both sides.

**Before shipping a persistence change**, ask `moc` rather than reasoning:

```bash
moc $(mops sources) --default-persistent-actors --implicit-package=core \
    --stable-types -o /tmp/new.wasm src/backend/main.mo   # emits /tmp/new.most
moc --stable-compatible /tmp/old.most /tmp/new.most
```

Two gotchas that check confirms:

1. **Making a `transient` var stable resets it one last time.** The variable is
   absent from the *deployed* stable signature, so EOP initialises it from its
   declaration. Set the value **after** that deploy; it persists from then on.
2. **It is a one-way door.** Rolling back past the change is refused
   (`M0169: stable variable … cannot be implicitly discarded`) without an
   explicit migration function. Fail-closed, but plan for it.

Related: `docs/pre-mainnet-checklist.md` (the production gate),
`tests/test_play_claim.sh`, `tests/test_oracle_xrc_fallback.sh`.
