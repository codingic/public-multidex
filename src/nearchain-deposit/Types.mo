// Domain types for the NEAR deposit detector.
//
// Shape is kept identical to ethchain-deposit's Types.mo so the Candid
// `getConfirmedDeposits` surface is the same across detectors and the DEX
// backend's pull logic works unchanged. Only the *meaning* of the fields
// differs: for NEAR, `asset`/`token` are the NEP-141 contract account id
// (e.g. "token.near", "usdt.tokens.near") rather than an ERC-20 address.

// A normalized inbound NEP-141 transfer — one ft_transfer event log.
type Transfer = {
  txHash : Text;
  logIndex : Nat;      // composite (receiptIdx*100000 + logIdx*100 + dataIdx) — drives the dedup key
  kind : Text;         // always "log" for NEAR (token transfer events)
  asset : Text;        // the NEP-141 token contract account id
  token : ?Text;       // same as asset (NEP-141 contract); null never happens for NEAR
  from : Text;         // sender NEAR account (event.old_owner_id)
  to : Text;           // recipient NEAR account (event.new_owner_id), a watched deposit address
  amountRaw : Nat;     // base units: token's integer amount (yocto-like smallest unit)
};

// A detected deposit (a Transfer plus where we saw it), stored in `deposits`.
// `confirmations` is refreshed each scan (= tip − blockHeight) and drives the
// move into `depositsConfirmed` once it reaches CONFIRMED_BLOCKS.
type Deposit = {
  txHash : Text;
  logIndex : Nat;
  kind : Text;
  asset : Text;
  token : ?Text;
  from : Text;
  to : Text;
  amountRaw : Nat;
  blockHeight : Nat;
  confirmations : Nat;
};
