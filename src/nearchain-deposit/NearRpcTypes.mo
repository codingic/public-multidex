// IC management-canister HTTPS-outcall interface used to reach the NEAR RPC.
//
// There is no official IC-native NEAR RPC canister (the ETH detector uses the
// DFINITY EVM-RPC canister). NEAR is reached the standard ICP way: call the
// management canister (aaaaa-aa) `http_request` method, which performs an
// HTTPS outcall and returns the response body. We POST JSON-RPC to the NEAR
// RPC endpoint and parse the JSON result ourselves.

module NearRpcTypes {

  public type HeaderField = { name : Text; value : Text };

  public type HttpRequestArgs = {
    url : Text;
    max_response_bytes : ?Nat64;
    method : { #get; #head; #post };
    headers : [HeaderField];
    body : ?Blob;
    // Optional response transform. We pass null (no certified transformation
    // needed — deposit detection trusts the RPC response, not a transform).
    transform : ?TransformRawResponse;
  };

  public type HttpResponse = {
    status : Nat;
    headers : [HeaderField];
    body : Blob;
  };

  public type TransformRawResponse = {
    function : shared query (
      { status : Nat; headers : [HeaderField]; body : Blob },
      Blob,
    ) -> async ({ status : Nat; headers : [HeaderField]; body : Blob });
    context : Blob;
  };

  // The IC management canister. `http_request` is a query method callable from
  // an update context; we await it and attach cycles at the call site.
  public type Management = actor {
    http_request : HttpRequestArgs -> async HttpResponse;
  };
};
