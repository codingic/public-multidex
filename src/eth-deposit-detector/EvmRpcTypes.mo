// EVM-RPC canister Candid types + the EvmRpc / Backend / Management actor
// interfaces used by the ETH deposit detector.
//
// Verbatim from dfinity/evm-rpc-canister candid/evm_rpc.did (main branch). Only
// the members this detector uses are exercised, but the full structs are
// declared so Candid decoding matches the wire exactly (no IC0503 drift).

// ── RPC service descriptors ───────────────────────────────────
type BlockTag = {
  #Earliest; #Safe; #Finalized; #Latest; #Number : Nat; #Pending;
};
// Ethereum mainnet services this detector may use. This detector targets
// STRICTLY Ethereum L1 (mainnet) — it never targets L2 chains (Arbitrum, Base,
// Optimism, …) nor testnets (Sepolia). Those selectors were intentionally
// removed from these types so the compiler forbids constructing an L2 request.
type EthMainnetService = {
  #Alchemy; #Ankr; #BlockPi; #Cloudflare; #PublicNode; #Llama;
};
type HttpHeader = { value : Text; name : Text };
type RpcApi = { url : Text; headers : ?[HttpHeader] };
type ProviderId = Nat64;
type ChainId = Nat64;
type RpcService = {
  #Provider : ProviderId;
  #Custom : RpcApi;
  #EthMainnet : EthMainnetService;
};
type RpcServices = {
  #Custom : { chainId : ChainId; services : [RpcApi] };
  #EthMainnet : ?[EthMainnetService];
};
type RejectionCode = {
  #NoError; #CanisterError; #SysTransient; #DestinationInvalid;
  #Unknown; #SysFatal; #CanisterReject;
};
type ProviderError = {
  #TooFewCycles : { expected : Nat; received : Nat };
  #MissingRequiredProvider;
  #ProviderNotFound;
  #NoPermission;
  #InvalidRpcConfig : Text;
};
type ValidationError = {
  #Custom : Text;
  #InvalidHex : Text;
};
type HttpOutcallError = {
  #IcError : { code : RejectionCode; message : Text };
  #InvalidHttpJsonRpcResponse : {
    status : Nat16; body : Text; parsingError : ?Text;
  };
};
type RpcError = {
  #JsonRpcError : { code : Int64; message : Text };
  #ProviderError : ProviderError;
  #ValidationError : ValidationError;
  #HttpOutcallError : HttpOutcallError;
};
type ConsensusStrategy = {
  #Equality;
  #Threshold : { total : ?Nat8; min : Nat8 };
};
type RpcConfig = {
  responseSizeEstimate : ?Nat64;
  responseConsensus : ?ConsensusStrategy;
};

// ── Log / block types ─────────────────────────────────────────
type LogEntry = {
  transactionHash : ?Text;
  blockNumber : ?Nat;
  data : Text;
  blockHash : ?Text;
  transactionIndex : ?Nat;
  topics : [Text];
  address : Text;
  logIndex : ?Nat;
  removed : Bool;
};

// ── eth_getLogs types (typed SDK) ───────────────────────────
type GetLogsRpcConfig = {
  responseSizeEstimate : ?Nat64;
  responseConsensus : ?ConsensusStrategy;
  maxBlockRange : ?Nat32;
};
type GetLogsArgs = {
  fromBlock : ?BlockTag;
  toBlock : ?BlockTag;
  addresses : [Text];
  topics : ?[[Text]];   // Topic = vec text; [[TRANSFER_SIG]] filters Transfer events
};
type GetLogsResult = { #Ok : [LogEntry]; #Err : RpcError };
type MultiGetLogsResult = {
  #Consistent : GetLogsResult;
  #Inconsistent : [(RpcService, GetLogsResult)];
};

type Block = {
  miner : Text;
  totalDifficulty : ?Nat;
  receiptsRoot : Text;
  stateRoot : Text;
  hash : Text;
  difficulty : ?Nat;
  size : Nat;
  uncles : [Text];
  baseFeePerGas : ?Nat;
  extraData : Text;
  transactionsRoot : ?Text;
  sha3Uncles : Text;
  nonce : Nat;
  number : Nat;
  timestamp : Nat;
  transactions : [Text];      // tx HASHES — full tx recovered via eth_getTransactionByHash
  gasLimit : Nat;
  logsBloom : Text;
  parentHash : Text;
  gasUsed : Nat;
  mixHash : Text;
};
type GetBlockByNumberResult = { #Ok : Block; #Err : RpcError };
type MultiGetBlockByNumberResult = {
  #Consistent : GetBlockByNumberResult;
  #Inconsistent : [(RpcService, GetBlockByNumberResult)];
};
type JsonRequestResult = { #Ok : Text; #Err : RpcError };
type MultiJsonRequestResult = {
  #Consistent : JsonRequestResult;
  #Inconsistent : [(RpcService, JsonRequestResult)];
};

// ── Actor interfaces (external canisters) ────────────────────
// The subset of the EVM-RPC surface this detector calls.
type EvmRpc = actor {
  // Full block by number (transactions are returned as HASHES).
  eth_getBlockByNumber : (RpcServices, ?RpcConfig, BlockTag) -> async MultiGetBlockByNumberResult;
  // Typed ERC-20 Transfer log retrieval for a block (no JSON parsing needed).
  eth_getLogs : (RpcServices, ?GetLogsRpcConfig, GetLogsArgs) -> async MultiGetLogsResult;
  // Raw JSON-RPC aggregator (multi-provider consensus). Used ONLY to issue
  // eth_getTransactionByHash (the SDK exposes no Candid method for it); result
  // is the raw JSON-RPC response Text, parsed with mo:json.
  multi_request : (RpcServices, ?RpcConfig, json : Text) -> async MultiJsonRequestResult;
};

// ── Threshold-ECDSA (IC management canister) ─────────────────
type EcdsaCurve = { #secp256k1 };
type EcdsaKeyId = { curve : EcdsaCurve; name : Text };
type EcdsaPublicKeyArgs = { canister_id : ?Principal; derivation_path : [Blob]; key_id : EcdsaKeyId };
type EcdsaPublicKeyResult = { public_key : Blob; chain_code : Blob };
type Management = actor {
  ecdsa_public_key : (EcdsaPublicKeyArgs) -> async EcdsaPublicKeyResult;
};
