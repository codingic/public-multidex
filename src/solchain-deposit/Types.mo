// Domain types for the Solana (SOL) deposit detector.

// A normalized inbound transfer — native SOL or an SPL token.
type Transfer = {
  signature : Text;
  slot : Nat;         // Solana slot the tx landed in (null→0)
  asset : Text;       // "SOL" or the SPL mint address
  token : ?Text;      // null for native; mint address for SPL
  from : Text;        // sender account (base58)
  to : Text;          // recipient account (base58) — a watched deposit address
  amountRaw : Nat;    // base units: lamports for SOL, token base units for SPL
  // stable dedup key for this transfer, built from the tx + instruction index
  dedupKey : Text;
};

// A detected deposit (a Transfer plus where/when we saw it), stored in
// `deposits`. `confirmations` is refreshed each scan (= tip − slot) and drives
// the move into `depositsConfirmed` once it reaches CONFIRMED_BLOCKS.
type Deposit = {
  signature : Text;
  slot : Nat;
  asset : Text;
  token : ?Text;
  from : Text;
  to : Text;
  amountRaw : Nat;
  blockHeight : Nat;   // slot at detection time (alias of `slot`)
  confirmations : Nat;
  dedupKey : Text;
};
