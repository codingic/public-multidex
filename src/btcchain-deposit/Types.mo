// Domain types for the Bitcoin (BTC) deposit detector.

// A normalized inbound transfer — native BTC (UTXO model).
// `signature` reuses the generic field name but for BTC it is the UTXO
// outpoint (txid#vout), which doubles as the stable dedup key.
type Transfer = {
  outpoint : Text;    // txid#vout — the stable dedup key
  asset : Text;       // "BTC"
  token : ?Text;      // null for native BTC
  from : Text;        // sender — not surfaced by get_utxos, left empty
  to : Text;          // recipient (a watched deposit address)
  amountRaw : Nat;    // base units: satoshis
};

// A detected deposit (a Transfer plus where we saw it), stored in `deposits`.
// `confirmations` is refreshed each scan (= tip − height + 1) and drives the
// move into `depositsConfirmed` once it reaches CONFIRMED_CONFIRMATIONS.
type Deposit = {
  signature : Text;   // outpoint (txid#vout)
  slot : Nat;         // block height of the UTXO (0 == unconfirmed/mempool)
  asset : Text;
  token : ?Text;
  from : Text;
  to : Text;
  amountRaw : Nat;
  blockHeight : Nat;  // alias of `slot`
  confirmations : Nat;
  dedupKey : Text;    // == `signature` for BTC
};
