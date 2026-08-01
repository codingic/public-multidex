# Published Candid interface

`backend.did` is the **published Candid interface** of the MULTI/DEX backend canister —
the machine-readable list of every public method with its argument and return types.

## Two ways to get it

- **Live, from the deployed canister.** The backend serves this as **public `candid:service`
  metadata** (the build passes `--public-metadata candid:service`; see `mops.toml`), so remote
  tooling — e.g. the IC MCP connector's `ic_describe_api` — can fetch the typed interface directly
  from the canister with no repo checkout.
- **Here, versioned.** This committed copy is the reviewable stability contract, diffable in PRs.

## Signatures vs. semantics

Candid describes **shapes, not behavior.** It won't tell you that market/limit orders return with
*no fills* and you poll for the outcome (sealed/staged matching), that all money is a `Nat` scaled
by 10⁸, that there's a $100k lifetime deposit cap, or how the dead-man switch works. For that, call
the **`getApiDoc()`** query on the canister — the guide to the non-obvious semantics — and
`getMarketSpecs()` for the live numeric constants.

## Stability

Additive-only within a major `apiVersion` (see `MM_API_VERSION` / `getMarketSpecs`): new methods and
new optional fields may appear; existing signatures don't change or disappear without a major bump.

### Major bumps so far

- **2.0.0 — July 2026.** The public trade feeds — `getRecentTrades`, `getAllTrades`,
  `getTradesSince` — now return **de-identified `PublicTrade`** records (no maker/taker
  principals). Bots parsing the old `Trade` shape from these three methods must switch to
  `PublicTrade`; your *own* fills (with fees and order ids) are unchanged via
  `getMyTradesSinceId` / `getMarketChanges`. Account-attributed history remains available on the
  public archive tape, which proof-of-reserves requires. Everything else in 2.0.0 is additive —
  notably the liquidation-transparency queries (`getMarginHeatmap`, `getMarginHeatmaps`,
  `getMarginHeatmapHistory`, `getMarginRiskSummary`).

## Regenerating

Run `scripts/gen-did.sh` after any change to the backend's public method surface, and commit the
result. It builds the backend and writes this file (do not hand-edit it).
