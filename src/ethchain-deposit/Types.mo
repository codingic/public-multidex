// Domain types for the ETH deposit detector.

// A normalized inbound transfer — native ETH or ERC-20.
type Transfer = {
  txHash : Text;
  logIndex : Nat;      // 0 for native ETH; receipt log index for ERC-20
  asset : Text;        // "ETH" or the token contract address
  token : ?Text;       // null for native; contract address for ERC-20
  from : Text;
  to : Text;           // recipient (a watched deposit address)
  amountRaw : Nat;     // base units: wei for ETH, token base units for ERC-20
};

// A detected deposit (a Transfer plus where we saw it), stored in `deposits`.
// `confirmations` is refreshed each scan (= tip − blockHeight) and drives the
// move into `depositsConfirmed` once it reaches CONFIRMED_BLOCKS.
type Deposit = {
  txHash : Text;
  logIndex : Nat;
  asset : Text;
  token : ?Text;
  from : Text;
  to : Text;
  amountRaw : Nat;
  blockHeight : Nat;
  confirmations : Nat;
};
