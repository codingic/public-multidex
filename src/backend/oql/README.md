# Vendored: OQL — Object Query Layer for Motoko (`mo:oql`)

This directory is a **vendored copy** of DFINITY's OQL library — a Motoko
object-query layer that lets a canister expose a queryable, navigable view over
data it already keeps in memory (schema discovery, filtered/sorted/aggregated
queries, edge joins, and per-caller row-level authorization).

- **Upstream:** https://github.com/caffeinelabs/oql-prototype
- **Vendored from:** upstream `main` @ `1981d6a` (2026-07-26)
- **Copyright:** © DFINITY Foundation
- **License:** Apache-2.0 (as declared in the upstream `mops.toml`) — see
  [LICENSE](LICENSE) in this directory. The rest of this repository is MIT;
  this directory is the exception.

It is vendored (rather than a package dependency) because the upstream is not
on the mops registry. The `.mo` sources here are **byte-identical to upstream**
— local integration (entity declarations, auth levels, the `Expose` include)
lives in `src/backend/main.mo`, not in patches to this directory.

## Re-vendoring procedure

1. Clone upstream and copy `src/*.mo` over this directory (expect a 1:1 file
   set; do not keep local edits here).
2. Watch the auth surface: entity authorization is **per-entity `TableAuth`**
   resolved per caller; the `Expose` mixin config accepts only `{ entities }`.
   Passing stale extra config fields still compiles — Motoko's structural
   subtyping silently ignores them — so verify the per-entity `.auth(...)` /
   `.public_()` / `.ownedBy(...)` declarations in `main.mo` still express the
   intended policy after every upgrade.
3. If upstream removes or reshapes any **stable** state that an older vendored
   mixin declared, the next canister upgrade needs a one-shot inline migration
   (see the `oqlMintedTokens` drop in this repo's history).
4. Run `bash scripts/lint-ratchet.sh` (this directory is excluded from lintoko
   as third-party code) and `mops test`, then upgrade a local canister and
   smoke `schema()` / `execute()` / `archiveExecute()` before shipping.
