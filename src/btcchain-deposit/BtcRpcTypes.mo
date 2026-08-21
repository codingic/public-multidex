// Bitcoin (BTC) deposit detector — Candid interface for the dfinity bitcoin
// canister (https://github.com/dfinity/bitcoin-canister, mainnet principal
// mgi-tqaaaa-aaaar-qaqoa-cai). The bitcoin canister exposes typed methods (no
// JSON-RPC envelope), so we decode typed Candid directly. We declare the
// members this detector calls: block-by-block scanning needs the height,
// header (for block hashes) and raw-block endpoints in addition to the legacy
// UTXO helpers.

// mainnet / testnet / regtest
type BitcoinNetwork = {
  #mainnet;
  #testnet;
  #regtest;
};

// pagination / scope filter for get_utxos
type UtxoFilter = {
  #min_confirmations : Nat32;
  #max_number_of_utxos : Nat32;
};

// a transaction output reference
type Outpoint = {
  txid : Blob;   // 32-byte transaction id
  vout : Nat32;  // output index within the transaction
};

// an unspent output at a watched address
type Utxo = {
  outpoint : Outpoint;
  value : Nat64;   // amount in satoshis
  height : Nat32;  // block height where it was created; 0 == unconfirmed (mempool)
};

type GetUtxosRequest = {
  address : Text;
  network : BitcoinNetwork;
  filter : ?UtxoFilter;
};

type GetUtxosResponse = {
  utxos : [Utxo];
  tip_height : Nat32;   // current chain tip (for confirmation depth)
};

type GetBalanceRequest = {
  address : Text;
  network : BitcoinNetwork;
  min_confirmations : ?Nat32;
};

type GetBalanceResponse = {
  balance : Nat64;
};

// ── block-by-block scanning primitives ─────────────────────────
// one block header; `block_hash` is what we feed into get_block
type BlockHeader = {
  version : Int32;
  prev_blockhash : Blob;
  merkle_root_hash : Blob;
  time : Nat32;
  bits : Nat32;
  nonce : Nat32;
  block_hash : Blob;
};

type GetCurrentBlockHeightRequest = {
  network : BitcoinNetwork;
};
type GetCurrentBlockHeightResponse = {
  height : Nat32;
};

type GetBlockHeadersRequest = {
  network : BitcoinNetwork;
  start_height : Nat32;
  end_height : ?Nat32;
};
type GetBlockHeadersResponse = {
  headers : [BlockHeader];
};

// raw block bytes (full serialized block) — we decode this ourselves
type GetBlockRequest = {
  network : BitcoinNetwork;
  block_hash : Blob;
};
type GetBlockResponse = {
  block : Blob;
};

// Actor interface (subset used by the detector).
type BitcoinApi = actor {
  get_utxos : (GetUtxosRequest) -> async (GetUtxosResponse);
  get_balance : (GetBalanceRequest) -> async (GetBalanceResponse);
  get_current_block_height : (GetCurrentBlockHeightRequest) -> async (GetCurrentBlockHeightResponse);
  get_block_headers : (GetBlockHeadersRequest) -> async (GetBlockHeadersResponse);
  get_block : (GetBlockRequest) -> async (GetBlockResponse);
};
