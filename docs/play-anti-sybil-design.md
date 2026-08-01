# Play-mode anti-Sybil — Google-verified Internet Identity

*2026-07-10. Status: PHASES 1–2 IMPLEMENTED (v0.84) — backend binding + allowance re-key + gate,
frontend 7.x auth migration + verify flow + Deposit unlock card + Google sign-in path. Verified
on the local sim end-to-end EXCEPT the live Google round trip (needs a human: sign in with a
Google-linked II, press Verify — the attribute popup can't be driven headlessly). Phase 3
(leaderboard eligibility, wash-detection fold, docs paragraph) pending. Play-deploy checklist:
append the play frontend origin to `frontend_origins`; on an EXISTING canister the env vars need
`icp canister settings update backend --add-environment-variable …` (yaml settings apply on
create/sync, not on plain redeploys). Companion to docs/deployment-modes.md (#play posture) and
the market-maker program's wash-invariant guardrail.*

## The attack

On #play every principal is minted $100k of lifetime deposit allowance. Nothing stops one human
from minting many principals: a throwaway account market-sells into the main account's low resting
bids (a crossing limit fills at the MAKER's price — the sealed pass and AMM priority don't prevent
maker-price fills of user bids), transferring most of its $100k to the main at $0.01 on the dollar.
The throwaway busts; the main tops the profit leaderboard, which scores exactly the thing the wash
transfers (equity − HODL baseline). Self-trade prevention is same-principal only; the ±100×
placement band barely constrains it. Every fee level, badge, Maker-League rank, and any future
play→production promise inherits the problem.

## Research answer: yes — and it is now first-class in Internet Identity

II supports **OpenID sign-in (Google, Apple, Microsoft)** alongside passkeys, and — the part that
matters — the **identity-attributes flow** lets a dapp demand a **signed, provider-scoped
`verified_email`** alongside the delegation:

- Frontend (`@icp-sdk/auth` ≥ 7.0, `@icp-sdk/core` ≥ 5.3): `authClient.requestAttributes({ keys:
  scopedKeys({ openIdProvider: 'google', keys: ['verified_email'] }), nonce })` — the scoped key
  (`openid:https://accounts.google.com:verified_email`) is only present when the II has a Google
  account linked AND Google marked the email verified. A passkey-only II simply has no such
  attribute → the gate fails closed until the user links Google in II.
- Backend (Motoko): the **`mo:identity-attributes` mixin** (`include IdentityAttributes({
  onVerified })`) injects the `_internet_identity_sign_in_start/finish` handshake and verifies the
  four things that make the bundle trustworthy — signer is the II canister
  (`rdmx6-jaaaa-aaaaa-aaadq-cai`; the IC checks signatures, not signers), frontend origin
  allowlisted, canister-minted single-use nonce, freshness. Config via `icp.yaml` env vars
  (`trusted_attribute_signers`, `frontend_origins`).
- **Toolchain: ready today.** moc 1.9.0 (needs ≥ 1.6), core 2.5.0 (exact requirement), and the
  repo already uses the `include` mixin pattern (AdminOps). The one real migration: the frontend
  is on the 5.x-style `AuthClient.create` API, which has **no `requestAttributes`** — upgrading
  to the 7.x promise API is part of the cost.
- `email` vs `verified_email` matters: `email` is user-supplied and unchecked; only
  `verified_email` (provider-attested) gates anything.

## Design: gate the value, not the door

Do NOT hard-require Google on sign-in — that adds friction for browsers-by and excludes passkey
purists for no gain (an unfunded account can't trade anyway). On #play the **deposit allowance is
the only on-ramp**, so make the verified email the scarce resource:

1. **Binding.** On a successful attributes handshake, `onVerified` normalizes the email
   (lowercase; for `gmail.com`/`googlemail.com` strip dots and `+suffix` — plus-addressing and
   dot-variants are free aliases), then stores a **salted hash** two-way:
   `emailBindings : hash → principal`, `principalEmail : principal → hash`. First-come binding;
   rebinding only via admin (support path). **The raw email is never stored and never journaled**
   — the ledger and archive are public by design, and must stay email-free.
2. **Allowance keys off the email, not the principal.** `creditAndRegister` on #play requires the
   caller to be bound, and `PLAY_DEPOSIT_CAP_USD` lifetime accounting moves to the email hash. A
   second principal on the same Google account gets $0 — the wash-funding vector dies. Binding
   maps survive `resetExchange` exactly like the allowance ledger does.
3. **Leaderboard + prizes require a binding** (display and eligibility) — unbound principals trade
   fine but compete for nothing.
4. **Google only, deliberately.** Apple must NOT be accepted: Hide-My-Email mints unlimited
   verified `@privaterelay.appleid.com` addresses — a Sybil faucet with a provider signature.
   Microsoft personal accounts are similar-but-murkier; revisit if demanded. The mechanism
   generalizes; the uniqueness guarantee does not.

## Surfacing the requirement

Nobody is told "you can't sign in" — the rule is communicated as what verification *unlocks*, at
the moment of need:

- **Sign-in modal: a choice, not a gate.** `openIdProvider: 'google'` makes sign-in itself the
  Google flow, with the scoped attributes riding along in the same interaction (implicit consent,
  no second prompt). Offer two labeled paths: **"Sign in with Google — full play account ($100k
  play balance, leaderboard)"** and **"Sign in with passkey — browse; verify later to fund and
  compete."** The Google path never surfaces the requirement at all.
- **Deposit page = the enforcement point and the persuasion point.** Unbound accounts see the
  deposit form replaced by an unlock card: *"Unlock your $100k play balance. One funded account
  per player keeps the competition honest — verify once with a Google-linked Internet Identity."*
  → [Verify with Google]. Two footnotes carry the load: the privacy line (*"we keep only a salted
  fingerprint of your email; the address itself is never stored and never touches the public
  ledger"* — true by construction, and the sentence that decides whether a crypto-native user
  proceeds), and the escape hatch (*"no Google on your II yet? Link one in your II settings at
  id.ai, then verify"*).
- **Leaderboard nudge.** Unbound rows show "unranked — verify to compete" linking to the same
  flow. Trading never nags: an unfunded account can't trade, so the funnel routes through the
  Deposit gate naturally.
- **Failure states map to actions**: email already bound → "this Google account already unlocked
  a play account — one per player; sign in with that identity" plus a support path for
  legitimate rebinds (lost passkey); consent declined / stale bundle → plain retry.
- **ANSWERED (observed live, 2026-07-10): II offers NO inline Google-linking in the attributes
  flow.** A Google-scoped `requestAttributes` against a passkey-only II leaves the id.ai window
  BLANK — no response, no error, indefinitely. And silent detection is impossible by design:
  II tells a dapp nothing about the session (no auth method, no linked accounts) — attributes
  only flow through a consented popup. Final resolution (v0.90): **one action, no verify
  button at all.** The standalone attribute request was removed outright — even demoted behind
  an "I've linked Gmail" claim, users click it unlinked and get the blank page. The card offers
  only **"Sign in with Google"** (the combined signIn+requestAttributes interaction; nonce
  minted by a throwaway Ed25519 identity since inspect refuses anonymous ingress), plus prose
  for the keep-my-identity case: *add Google as an access method at id.ai, then press the same
  button* — an access method unlocks the SAME II, so the per-dapp principal is unchanged and
  the account is kept. **No sign-out/sign-in cycle is needed**; pressing the button IS the
  re-sign-in. Without the id.ai step the button lands on a fresh Google-backed identity —
  costless, since unverified accounts hold no funds. Popup rule bakes into all of it: every
  window-bound request starts synchronously inside the click gesture, nonces passed as
  promises.
- **Docs, not banner.** #docs/launch gains a "fair play" paragraph (one player, one funded
  account, how and why); the launch banner stays uncluttered.

## Honest Sybil math

This is a cost **raiser**, not a wall. Today a sybil costs ~10 seconds (new passkey II). After:
a fresh Google account (minutes, sometimes phone verification, increasingly rate-limited by
Google) per $100k of allowance. A determined farmer still farms — so the identity gate pairs with
**detection**, which this venue is unusually good at: every fill is public with raw principals in
the tamper-evident ledger, so a published wash-detection fold (counterparty-concentration per
account: % of profit earned against ≤k counterparties, funding-lineage clustering) plus a
disqualification policy (the market-maker program's terms page) covers the residual. Escalation
path if stakes rise (production, real prizes): a proof-of-unique-humanity verifiable credential —
same II-brokered plumbing, much stronger and much higher friction.

## Alternatives considered

- **Direct in-canister Google OIDC** (verify Google's JWT against its JWKS via HTTPS outcalls —
  what II itself does internally): workable but re-builds what II now exposes, adds key-rotation
  plumbing, and loses II's per-dapp principal privacy. Rejected.
- **NFID / third-party email wallets**: superseded by II's native OpenID support. Rejected.
- **Hard Google gate on sign-in**: friction with no security gain over gating the allowance.
  Rejected.

## Plan (when scheduled)

| Phase | Scope | Est. |
|---|---|---|
| 1 | Backend: `mops add identity-attributes`, `include IdentityAttributes`, normalization + salted-hash binding maps, re-key play allowance by email hash, gate `creditAndRegister`, `icp.yaml` env vars | ~1 d |
| 2 | Frontend: `@icp-sdk/auth` 5.x→7.x migration, attributes handshake, Deposit-page "Verify with Google to unlock your $100k" UX, optional `openIdProvider: 'google'` one-click | 1–1.5 d |
| 3 | Leaderboard/prize eligibility gate + wash-detection fold over the ledger + docs (#docs/launch + #docs/levels honesty notes) | ~1 d |

Open items: pick the salt custody (canister-held vs derived — a public salt makes brute-forcing a
known email trivial, so salt must be a private stable secret); decide the unbind/support flow;
verify the 7.x client against the play gateway origin set (`frontend_origins` must list every
origin the app is served from, or `_finish` rejects with `#FrontendOriginMismatch`).
