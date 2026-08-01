# Wallet + Positions — locked architecture (model 2)

*2026-06-11. Locks the two-tier model agreed in discussion. Supersedes the whole-wallet cross-margin model, which is being removed (no legacy users; dev reset authorized).*

## The two tiers

**Wallet** — what you can withdraw.
- Holds virtual balances of each token (BTC/ETH/SOL/ICP/ICPUSD), one ledger entry per (user, token) in `Accounts` under the user's own principal.
- Backed (in production) by chain-key custody: each user gets a per-asset deposit address; tokens sent there (incl. directly from a CEX) are credited to the virtual balance after finality. The tokens stay at the deposit addresses; the balance shown is virtual. **Solvency invariant: Σ virtual balances ≤ Σ custodied tokens, per asset, always.** Tokens move on-chain only on withdrawal (and batched consolidation — see below).
- Supports: **deposit** (show address → credit on finality), **withdraw** (move custody → user's external address), and **spot** (wallet↔wallet conversion, both sides withdrawable). No leverage, no margin, no positions involved.

**Positions** — leverage and short, via collateral pools.
- To gain leveraged or short exposure you **move ICPUSD margin from the Wallet into a margin pool** (`fundMarginPool`), then open a position. The pool is a user-owned sub-account principal; it borrows from the AMM vault for the leveraged part. Vault = lender, never counterparty.
- **PnL settles pool-first.** Closing a position repays its debt from proceeds; the residual (profit or loss) lands in the **pool's equity** as ICPUSD, not in the Wallet. Profit flows pool → Wallet only when the user withdraws margin (gated on remaining positions staying ≥ initial health). This pool-first rule is what makes cross-margin correct (a winner backs its siblings) and bounds loss to the pool (the Wallet is untouchable; worst case a pool liquidates to zero).
- Isolated = one position/pool (loss bounded to that margin); cross = many positions share a pool's equity (capital-efficient, intra-pool contagion is the opt-in).
- **Margin is ICPUSD-only.** Want exposure backed "by your BTC"? Spot-convert in the Wallet first, fund the pool with cash. Keeps pool equity scalar and liquidation math trivial; multi-collateral pools are a later opt-in.

So: **deposit → Wallet; spot trades stay in the Wallet; to trade with leverage/short, move cash into a pool and open positions; closing/withdrawing flows value back to the Wallet; withdraw → off-chain.**

## What this removes

The whole-wallet cross-margin model (your free balance was LTV-weighted collateral; `openMarginAccount`/`borrowAsset`/`repayAsset`) is gone. The Wallet is **pure custody — never collateral**. This structurally eliminates the collateral-escape class (nothing to escape: the Wallet doesn't back loans; only pool balances do). The borrow/liquidation/insurance engine (`BorrowEngine`/`Liquidator`/`MarginEngine`) stays — pools use it on pool principals.

## Custody / consolidation plan (production; deferred)

The deposit set behaves like a UTXO set even on account chains (each address is an independent balance). Pure-lazy custody fragments (withdrawal cost grows with account age; ETH hits the gas-station problem); sweep-every-deposit is too tx-heavy. **Policy: a single per-asset hot pool, fed by batched opportunistic consolidation** (low-fee windows, dust thresholds, age) — not per-deposit. Withdrawals serve from the pool as one predictable tx. Per-chain:
- **BTC** — ckBTC minter already gives a per-principal deposit address that works from a CEX; consolidate UTXOs in low-fee windows.
- **ETH/ERC-20 (USDC)** — the standard ckETH/ckERC20 deposit needs the principal in calldata, which **a CEX withdrawal can't attach** → use per-user threshold-signed addresses (custom custody) + a forwarder/contract to dodge the gas-station problem.
- **SOL** — native threshold-Ed25519 custody + RPC monitoring; sweep freely (cheap), reclaim rent on dust accounts.

Each outbound tx also costs IC threshold-signing cycles → favor fewer, larger txs.

## ICPUSD = USDC + USDT (basket)

ICPUSD is a stablecoin basket so users can deposit either. Risk: a depeg of one leg is shared by all ICPUSD holders. **Track the backing mix** (not a single number), honor withdrawals against what's actually held per stable, and add a depeg circuit-breaker. Internally fungible 1:1 only while both hold the peg.

## Dev-mode scaffolding (this implementation)

Chain-key custody is future infra. For dev: **deposit** = the existing test faucet credits the Wallet (and `getDepositAddress` returns a clearly-marked placeholder); **withdraw** = validate available Wallet balance, decrement it, log the withdrawal (no real chain tx yet). The model, ledger, and UI are real; only the custody backend is stubbed.

## Phasing
1. Lock this doc. 2. Backend: remove whole-wallet margin surface. 3. Backend: Wallet deposit/withdraw scaffolding. 4. Frontend: Wallet section, remove margin box, keep Positions. 5. Deploy + reset + reseed. 6. (Later) chain-key custody backend + consolidation; repoint whole-wallet margin tests to pools.
