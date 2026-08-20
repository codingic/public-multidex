// Solana (SOL) deposit detector — Candid interface for the dfinity sol-rpc
// canister (https://github.com/dfinity/sol-rpc-canister, mainnet principal
// tghme-zyaaa-aaaar-qarca-cai).
//
// Mirrors the role of EvmRpcTypes.mo for the ETH detector: we declare ONLY the
// members this detector actually calls. The sol-rpc canister exposes typed
// methods (getSignaturesForAddress / getTransaction / getSlot …) plus a generic
// `jsonRequest` that forwards any Solana JSON-RPC payload — we use `jsonRequest`
// for everything so the response comes back as raw JSON-RPC Text and is parsed
// with mo:json (same shape as the ETH detector's multi_request). The structs
// below are declared so Candid decoding matches the wire exactly.

// ── cluster + provider selectors ─────────────────────────────
type SolanaCluster = {
  #Mainnet; #Devnet; #Testnet;
};
type SupportedProvider = {
  #AlchemyMainnet; #AlchemyDevnet; #AnkrMainnet; #AnkrDevnet;
  #ChainstackMainnet; #ChainstackDevnet; #DrpcMainnet; #DrpcDevnet;
  #HeliusMainnet; #HeliusDevnet; #PublicNodeMainnet;
};
type ConsensusStrategy = {
  #Equality;
  #Threshold : { total : ?Nat8; min : Nat8 };
};
type HttpHeader = { value : Text; name : Text };
type RpcEndpoint = { url : Text; headers : ?[HttpHeader] };
type RpcAuth = {
  #BearerToken : { url : Text };
  #UrlParameter : { urlPattern : Text };
};
type RpcAccess = {
  #Authenticated : { auth : RpcAuth; publicUrl : ?Text };
  #Unauthenticated : { publicUrl : Text };
};
type RpcProvider = { cluster : SolanaCluster; access : RpcAccess };
type RpcSource = {
  #Supported : SupportedProvider;
  #Custom : RpcEndpoint;
};
// Let the canister pick providers, or list them explicitly.
type RpcSources = {
  #Custom : [RpcSource];
  #Default : SolanaCluster;
};
type RpcConfig = {
  responseSizeEstimate : ?Nat64;
  responseConsensus : ?ConsensusStrategy;
};

// ── error shapes (only the fields we may inspect) ───────────
type JsonRpcError = { code : Int64; message : Text };
type ProviderError = {
  #TooFewCycles : { expected : Nat; received : Nat };
  #InvalidRpcConfig : Text;
  #UnsupportedCluster : Text;
};
type HttpOutcallError = {
  #IcError : { code : RejectionCode; message : Text };
  #InvalidHttpJsonRpcResponse : { status : Nat16; body : Text; parsingError : ?Text };
};
type RejectionCode = {
  #NoError; #CanisterError; #SysTransient; #DestinationInvalid;
  #Unknown; #SysFatal; #CanisterReject;
};
type RpcError = {
  #JsonRpcError : JsonRpcError;
  #ProviderError : ProviderError;
  #ValidationError : Text;
  #HttpOutcallError : HttpOutcallError;
};

// ── generic jsonRequest result (raw JSON-RPC text) ──────────
type RequestResult = {
  #Ok : Text;
  #Err : RpcError;
};
type MultiRequestResult = {
  #Consistent : RequestResult;
  #Inconsistent : [(RpcSource, RequestResult)];
};

// ── Actor interface (subset used by the detector) ───────────
type SolRpc = actor {
  // Generic Solana JSON-RPC forwarder — same role as evm-rpc's multi_request.
  // We issue getSignaturesForAddress / getSlot / getTransaction through this.
  jsonRequest : (RpcSources, ?RpcConfig, json_rpc_payload : Text) -> async MultiRequestResult;
};
