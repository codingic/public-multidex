# Security Policy

## Reporting a vulnerability

Please report vulnerabilities **privately** via GitHub's private vulnerability
reporting on this repository: **Security → Report a vulnerability**
(https://github.com/dfinity/multidex/security/advisories/new).

Please do **not** open public issues or pull requests for security problems, and
do not test against deployments you do not operate beyond what is needed to
demonstrate the issue.

A useful report includes: the affected surface (canister method, page, script),
steps to reproduce, the impact you believe it has (funds, privacy, availability),
and — for exchange-logic issues — the market/pool state needed to trigger it.

## Status and scope

MULTI/DEX is a **research prototype under active development. It has not been
audited.** Public deployments run in `#play` posture: every balance is
play-money by construction (capped simulated deposits; no real-asset custody),
so vulnerabilities there are treated as correctness/robustness reports rather
than incidents. There is currently **no bug bounty**; reports are handled on a
best-effort basis.

Findings we especially care about:

- **Solvency and conservation** — anything that mints, loses, or double-counts
  value across the ledger, order books, AMM vault, margin pools, insurance fund
  or treasury.
- **Authorization and scoping** — reading or acting on another principal's
  balances, orders, positions, or history (including through the OQL query
  surface and its per-caller row scoping).
- **Ledger integrity** — breaking the hash chain, the certified head, or the
  archive's append-only guarantees without detection.
- **Matching fairness** — bypassing the sealed staging/release pass, priority
  rules, or self-trade prevention.
- **Availability** — cheap ways to exhaust cycles, memory, or the staged-order
  queue past its shed defenses.

Out of scope: issues requiring a malicious controller (controllers are trusted
by definition until the NNS-controlled production posture), dev-only surfaces
(`#dev` test hooks, `xrc-mock`, `fuel-mock`), and volumetric denial of service
against public IC boundary infrastructure.

## Supported versions

Only the `main` branch (and the deployments built from its tip) is supported.

## Hardening notes for operators

The production gate lives in `docs/pre-mainnet-checklist.md`, and the
deployment-posture kill-matrix in `docs/deployment-modes.md`. Do not deploy the
dev mock canisters to value-bearing targets, and rotate any API keys that ever
appeared in git history before going public with a deployment.
