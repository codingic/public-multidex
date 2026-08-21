// SOL (Solana) deposit detector — PER-ADDRESS model (unlike ETH's block scan).
// The backend drives detection by calling `refreshAddressTx(addr)` for each
// watched address; the canister then pulls that address's recent transaction
// signatures (getSignaturesForAddress) and resolves each new one
// (getTransaction, jsonParsed, finalized), parsing inbound SOL / SPL transfers
// into `deposits` and archiving finalized ones into `depositsConfirmed`.
// No crediting — the DEX reads the archive.
//
// Address model:
//  - SOL : watch the owner wallet (watchedAddresses). An inbound system
//          transfer has destination == owner wallet.
//  - SPL : a wallet's token account (ATA) is DERIVED IN-CANISTER from
//          (owner, mint) via Ata.ataAddress — we never store ATAs. We MUST poll
//          the ATA, because for a pure inbound SPL transfer the owner wallet is
//          NOT in the tx's account list — only the ATA is. Matching still keys
//          off postTokenBalances (owner + mint), so extraction is unchanged.
//
// Commitment is `finalized` throughout → fetched txs are irreversible, so the
// confirmation countdown (CONFIRMED_SLOTS) is satisfied almost immediately.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Cycles "mo:core/Cycles";
import Json "mo:json";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Types "Types";
import SolRpcTypes "SolRpcTypes";
import Constants "Constants";
import Base58 "Base58";
import Ata "Ata";

persistent actor SolDepositDetector {

  func solRpc() : Principal {
    switch (_solRpcCache) { case (?p) { p }; case null { Constants.solRpcMainnet() } };
  };
  transient var _solRpcCache : ?Principal = Constants.solRpcEnv<system>();

  // owner wallet (base58) -> owning principal. SOL deposit addresses; used BOTH
  // as poll targets (SOL) and as the destination/owner match during extraction.
  let watchedAddresses = Map.empty<Text, Principal>();
  // base58 mint -> token-program id (legacy SPL "Tokenkeg…" or Token-2022
  // "Tokenz…"). Membership set of SPL tokens we monitor; the ATA for
  // (owner, mint) is DERIVED in-canister (Ata.mo), never stored.
  let watchedTokens = Map.empty<Text, Text>();

  // per-poll-address incremental cursor: newest signature already processed
  let lastSignature = Map.empty<Text, Text>();

  // reentrancy guard: at most one in-flight refresh per address
  let refreshing = Map.empty<Text, Bool>();

  // pending deposits, deduped by dedupKey (tx signature + direction + index)
  let deposits = Map.empty<Text, Types.Deposit>();
  // permanent archive of finalized deposits
  // TODO: unbounded growth — at millions of users this array grows forever and
  // inflates canister memory; needs bucketing / backend-consumption-then-prune.
  var depositsConfirmed : [Types.Deposit] = [];
  // keys already archived, so a re-fetched transfer isn't archived twice
  let confirmedKeys = Map.empty<Text, ()>();

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) { Runtime.trap("Caller is not a canister controller") };
  };

  public query func getDeployMode() : async Text { "production" };
  public query func cyclesBalance() : async Nat { Cycles.balance() };

  // watch an SPL token mint (legacy Token program). The ATA per owner is derived
  // in-canister. Token-2022 mints must use watchToken2022.
  public shared (msg) func watchToken(mint : Text) : async () {
    requireController(msg.caller);
    Map.add(watchedTokens, Text.compare, mint, Constants.TOKEN_PROGRAM_ID);
  };
  public shared (msg) func watchToken2022(mint : Text) : async () {
    requireController(msg.caller);
    Map.add(watchedTokens, Text.compare, mint, Constants.TOKEN_2022_PROGRAM_ID);
  };
  public shared (msg) func unwatchToken(mint : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedTokens, Text.compare, mint);
  };
  public query func getWatchedTokens() : async [Text] {
    Iter.toArray(Map.keys(watchedTokens));
  };
  public query func getWatchedTokenPrograms() : async [(Text, Text)] {
    Iter.toArray(Map.entries(watchedTokens));
  };

  // register a user's SOL deposit address (owner wallet); its inbound SOL and
  // (via its ATAs) SPL transfers are detected
  public shared (msg) func registerDepositAddress(owner : Principal, addr : Text) : async () {
    requireController(msg.caller);
    // base58 is case-sensitive, so no lowercasing. Require a genuine 32-byte
    // pubkey so the exact-match lookup against watchedAddresses is meaningful.
    if (not Base58.isValidSolanaAddress(addr)) { Runtime.trap("Invalid Solana address (must decode to a 32-byte pubkey)") };
    Map.add(watchedAddresses, Text.compare, addr, owner);
  };
  public shared (msg) func unregisterDepositAddress(addr : Text) : async () {
    requireController(msg.caller);
    ignore Map.delete(watchedAddresses, Text.compare, addr);
    ignore Map.delete(lastSignature, Text.compare, addr);
  };
  public query func getDepositAddresses() : async [Text] {
    Iter.toArray(Map.keys(watchedAddresses));
  };

  // SPL ATAs are DERIVED in-canister from (owner, mint) via Ata.ataAddress — no
  // registration needed. See refreshAddressTx.

  public query func getConfirmedDeposits() : async [Types.Deposit] {
    depositsConfirmed;
  };

  // raw JSON-RPC via sol-rpc's jsonRequest (multi-provider consensus); null on error
  func jsonRequest(payload : Text) : async ?Text {
    let rpc : SolRpcTypes.SolRpc = actor (Principal.toText(solRpc()));
    try {
      let r = await (with cycles = Constants.SOL_RPC_CYCLES) rpc.jsonRequest(Constants.SOL_CHAIN, null, payload);
      switch r {
        case (#Consistent x) { switch x { case (#Ok t) { ?t }; case (#Err _) { null } } };
        case (#Inconsistent _) { null };
      };
    } catch (_) { null };
  };

  // parse a JSON-RPC response envelope; returns the `result` Json, or null if
  // the envelope is malformed or carries a JSON-RPC error
  func resultOf(s : Text) : ?Json.Json {
    switch (Json.parse(s)) {
      case (#err _) { null };
      case (#ok j) {
        // JSON-RPC error object → treat as failure
        switch (Json.getAsObject(j, "error")) {
          case (#ok _) { null };
          case (#err _) {
            switch (Json.get(j, "result")) {
              case (?r) { ?r };
              case null { null };
            };
          };
        };
      };
    };
  };

  // base10 text -> Nat (jsonParsed returns amounts as base10 strings)
  func decToNat(s : Text) : Nat {
    var acc : Nat = 0;
    for (c in s.chars()) {
      let d = switch (c) {
        case ('0') { 0 }; case ('1') { 1 }; case ('2') { 2 }; case ('3') { 3 };
        case ('4') { 4 }; case ('5') { 5 }; case ('6') { 6 }; case ('7') { 7 };
        case ('8') { 8 }; case ('9') { 9 };
        case (_) { 0 }; // ignore stray chars
      };
      acc := acc * 10 + d;
    };
    acc;
  };

  // latest finalized slot (drives confirmation counting)
  func latestSlot() : async Nat {
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\",\"params\":[{\"commitment\":\"finalized\"}]}";
    switch (await jsonRequest(payload)) {
      case null { 0 };
      case (?s) {
        switch (resultOf(s)) {
          case null { 0 };
          case (?r) {
            switch (Json.getAsNat(r, "")) {
              case (#ok n) { n };
              case (#err _) { 0 };
            };
          };
        };
      };
    };
  };

  // getSignaturesForAddress — newest-first [(signature, slot)]; null on error.
  // `untilSig` bounds the bottom (returns only signatures NEWER than it, i.e.
  // the incremental cursor); `beforeSig` pages back to older signatures.
  func getSigs(addr : Text, untilSig : ?Text, beforeSig : ?Text, limit : Nat) : async ?[(Text, Nat)] {
    var cfg = "{\"commitment\":\"finalized\",\"limit\":" # Nat.toText(limit);
    switch (untilSig) { case (?s) { cfg #= ",\"until\":\"" # s # "\"" }; case null {} };
    switch (beforeSig) { case (?s) { cfg #= ",\"before\":\"" # s # "\"" }; case null {} };
    cfg #= "}";
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSignaturesForAddress\",\"params\":[\"" # addr # "\"," # cfg # "]}";
    switch (await jsonRequest(payload)) {
      case null { null };
      case (?s) {
        switch (resultOf(s)) {
          case null { null };
          case (?r) {
            // result is an array at the root
            switch (Json.getAsArray(r, "")) {
              case (#err _) { null };
              case (#ok arr) {
                let out = List.empty<(Text, Nat)>();
                for (e in arr.vals()) {
                  let sig = switch (Json.getAsText(e, "signature")) { case (#ok v) { v }; case (#err _) { "" } };
                  let slot = switch (Json.getAsNat(e, "slot")) { case (#ok n) { n }; case (#err _) { 0 } };
                  if (sig != "") { out.add((sig, slot)) };
                };
                ?List.toArray(out);
              };
            };
          };
        };
      };
    };
  };

  // getTransaction (jsonParsed, finalized) — (slot, txJson); null on error or
  // when the tx is not found / pruned (result is null, not an object)
  func getTx(sig : Text) : async ?(Nat, Json.Json) {
    let payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":[\""
      # sig
      # "\",{\"commitment\":\"finalized\",\"encoding\":\"jsonParsed\",\"maxSupportedTransactionVersion\":0}]}";
    switch (await jsonRequest(payload)) {
      case null { null };
      case (?s) {
        switch (resultOf(s)) {
          case null { null };
          case (?r) {
            switch (Json.getAsObject(r, "transaction")) {
              case (#err _) { null };
              case (#ok _) {
                let slot = switch (Json.getAsNat(r, "slot")) { case (#ok n) { n }; case (#err _) { 0 } };
                ?(slot, r);
              };
            };
          };
        };
      };
    };
  };

  // parse one fetched tx and record its inbound transfers. Failed txs (meta.err
  // is a non-null object) are skipped — they make no balance change.
  func processTxJson(tx : Json.Json, slot : Nat) {
    switch (Json.getAsObject(tx, "meta.err")) {
      case (#ok _) { return };
      case (#err _) {};
    };
    for (t in extractTransfers(tx, slot).vals()) { recordDeposit(transferToDeposit(t)) };
  };

  // extract all inbound transfers to watched addresses from one parsed tx.
  // `slot` is supplied by the caller (getTransaction's result.slot).
  func extractTransfers(tx : Json.Json, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let signature = switch (Json.getAsText(tx, "transaction.signatures[0]")) {
      case (#ok v) { v }; case (#err _) { "" };
    };
    if (signature == "") { return List.toArray(out) };

    // ── native SOL: walk instructions + inner instructions for system transfers
    let solHits = findSolTransfers(tx, signature, slot);
    for (t in solHits.vals()) { out.add(t) };

    // ── SPL tokens: walk postTokenBalances for watched-owner + watched-mint
    // increases (robust to inner instructions / ATA creation)
    let splHits = findSplTransfers(tx, signature, slot);
    for (t in splHits.vals()) { out.add(t) };

    List.toArray(out);
  };

  // system-program transfer instructions crediting a watched address
  func findSolTransfers(tx : Json.Json, signature : Text, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let instructions = allInstructions(tx);
    var idx = 0;
    for (ins in instructions.vals()) {
      let program = switch (Json.getAsText(ins, "program")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      let itype = switch (Json.getAsText(ins, "parsed.type")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      if (program == "system" and itype == "transfer") {
        let dest = switch (Json.getAsText(ins, "parsed.info.destination")) {
          case (#ok v) { v }; case (#err _) { "" };
        };
        let lamports = switch (Json.getAsText(ins, "parsed.info.lamports")) {
          case (#ok v) { v }; case (#err _) { "0" };
        };
        let amount = decToNat(lamports);
        if (amount > 0 and Map.get(watchedAddresses, Text.compare, dest) != null) {
          let from = switch (Json.getAsText(ins, "parsed.info.source")) {
            case (#ok v) { v }; case (#err _) { "" };
          };
          out.add({
            signature = signature;
            slot = slot;
            asset = Constants.ASSET;
            token = null;
            from = from;
            to = dest;
            amountRaw = amount;
            dedupKey = signature # "#sol#" # Nat.toText(idx);
          });
        };
      };
      idx += 1;
    };
    List.toArray(out);
  };

  // SPL Token Program ids (legacy + Token-2022). Used to decide whether a raw
  // (unparsed) instruction is a token-program call whose bytes we may decode.
  let SPL_TOKEN_PROGRAM = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
  let SPL_TOKEN_2022_PROGRAM = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

  // SPL token deposits, parsed instruction-by-instruction. Two paths:
  //  - parsed: jsonParsed supplied `parsed.type` / `parsed.info` (top-level and
  //    any parsed inner instructions).
  //  - raw: inner instructions in getTransaction jsonParsed are often NOT
  //    parsed (only `data` / `accounts` / `programIdIndex`); we decode the
  //    base58 `data` ourselves — discriminant byte[0] ∈ {3, 12}, amount = LE
  //    u64 at bytes[1:9] — exactly the canonical token layout. This catches
  //    transfers inside CPIs (DEX payouts, staking rewards, …) that a
  //    `parsed`-only scan would drop and that `postTokenBalances` alone cannot
  //    distinguish from `mintTo`.
  // Only `transfer` / `transferChecked` credit a deposit; `mintTo` / ATA
  // creation / Burn are excluded by construction. `from` is the sender wallet.
  func findSplTransfers(tx : Json.Json, signature : Text, slot : Nat) : [Types.Transfer] {
    let out = List.empty<Types.Transfer>();
    let post = switch (Json.getAsArray(tx, "meta.postTokenBalances")) {
      case (#ok a) { a }; case (#err _) { [] };
    };
    if (post.size() == 0) { return [] };
    // map every touched token account pubkey -> (owner, mint); used to resolve
    // both the destination (to credit) and the source (sender wallet).
    let acctInfo = Map.empty<Text, (Text, Text)>();
    for (b in post.vals()) {
      let ai = switch (Json.getAsNat(b, "accountIndex")) { case (#ok n) { n }; case (#err _) { 0 } };
      let mint = switch (Json.getAsText(b, "mint")) { case (#ok v) { v }; case (#err _) { "" } };
      let owner = switch (Json.getAsText(b, "owner")) { case (#ok v) { v }; case (#err _) { "" } };
      let pk = accountPubkey(tx, ai);
      if (pk != "") { Map.add(acctInfo, Text.compare, pk, (owner, mint)) };
    };
    let instructions = allInstructions(tx);
    var idx = 0;
    for (ins in instructions.vals()) {
      switch (splTransferOf(tx, ins)) {
        case (?(source, destination, amount)) {
          switch (Map.get(acctInfo, Text.compare, destination)) {
            case (?(owner, mint)) {
              // require BOTH from and to token accounts to appear in
              // postTokenBalances (mirrors the Go reference's dual
              // getPostTokenBalance guard); `from` is the sender wallet.
              switch (Map.get(acctInfo, Text.compare, source)) {
                case (?(srcOwner, _)) {
                  if (amount > 0 and Map.get(watchedTokens, Text.compare, mint) != null
                      and Map.get(watchedAddresses, Text.compare, owner) != null) {
                    out.add({
                      signature = signature;
                      slot = slot;
                      asset = mint;
                      token = ?mint;
                      from = srcOwner;
                      to = owner;
                      amountRaw = amount;
                      dedupKey = signature # "#spl#" # Nat.toText(idx);
                    });
                  };
                };
                case null {};
              };
            };
            case null {};
          };
        };
        case null {};
      };
      idx += 1;
    };
    List.toArray(out);
  };

  // Decode a single transfer / transferChecked instruction into
  // (source, destination, amount); returns null unless it is one.
  //  - parsed path: jsonParsed already supplied `parsed.type` (transfer /
  //    transferChecked) with `parsed.info.{source, destination, amount}`.
  //  - raw path: instruction was not parsed (typical for inner instructions in
  //    getTransaction jsonParsed); `data` is base58 — decode it and read the
  //    discriminant (byte[0]: 3 = transfer, 12 = transferChecked) and the LE-u64
  //    amount (bytes[1:9]); source / destination are `accounts[0]` / `accounts[1]`.
  func splTransferOf(tx : Json.Json, ins : Json.Json) : ?(Text, Text, Nat) {
    // --- parsed path ---
    let itype = switch (Json.getAsText(ins, "parsed.type")) {
      case (#ok v) { v }; case (#err _) { "" };
    };
    if (itype == "transfer" or itype == "transferChecked") {
      let destination = switch (Json.getAsText(ins, "parsed.info.destination")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      let source = switch (Json.getAsText(ins, "parsed.info.source")) {
        case (#ok v) { v }; case (#err _) { "" };
      };
      let amount = decToNat(switch (Json.getAsText(ins, "parsed.info.amount")) {
        case (#ok v) { v }; case (#err _) { "0" };
      });
      if (source != "" and destination != "" and amount > 0) {
        return ?(source, destination, amount);
      };
      return null;
    };
    // --- raw path (unparsed; e.g. inner instructions in getTransaction jsonParsed) ---
    let data = switch (Json.getAsText(ins, "data")) {
      case (#ok v) { v }; case (#err _) { "" };
    };
    if (data == "") { return null };
    // confirm it is a token program (legacy or 2022) before interpreting bytes
    let programId = switch (Json.getAsText(ins, "programId")) {
      case (#ok p) { p };
      case (#err _) {
        switch (Json.getAsNat(ins, "programIdIndex")) {
          case (#ok i) { accountPubkey(tx, i) };
          case (#err _) { "" };
        };
      };
    };
    if (programId != SPL_TOKEN_PROGRAM and programId != SPL_TOKEN_2022_PROGRAM) {
      return null;
    };
    switch (Base58.decodeBase58(data)) {
      case (?bytes) {
        if (bytes.size() < 9) { return null };
        let disc = Nat8.toNat(bytes[0]);
        if (disc != 3 and disc != 12) { return null };
        switch (Json.getAsArray(ins, "accounts")) {
          case (#ok accs) {
            // Account layout differs by instruction (matches the Go reference):
            //   transfer (3)        : [source, destination, authority]        -> dest = accounts[1], need >= 3
            //   transferChecked (12): [source, mint, destination, authority]   -> dest = accounts[2], need >= 4
            // (source is always accounts[0].)
            let dstPos = if (disc == 12) { 2 } else { 1 };
            let need = if (disc == 12) { 4 } else { 3 };
            if (accs.size() < need) { return null };
            let source = resolveAccountPubkey(tx, accs[0]);
            let destination = resolveAccountPubkey(tx, accs[dstPos]);
            if (source == "" or destination == "") { return null };
            let amount = leU64(bytes, 1);
            if (amount > 0) { return ?(source, destination, amount) } else { return null };
          };
          case (#err _) { return null };
        };
      };
      case null { return null };
    };
  };

  // little-endian u64 starting at byte offset `start` (8 bytes).
  func leU64(bytes : [Nat8], start : Nat) : Nat {
    var v : Nat = 0;
    var i = 7;
    while (i >= 0) {
      v := v * 256 + Nat8.toNat(bytes[start + i]);
      i := i - 1;
    };
    v;
  };

  // resolve a transaction account's pubkey by its message index. jsonParsed
  // returns accountKeys either as objects {pubkey,...} or plain strings
  // depending on encoding; handle both so the bridge to postTokenBalances'
  // accountIndex is robust.
  func accountPubkey(tx : Json.Json, index : Nat) : Text {
    let path = "transaction.message.accountKeys[" # Nat.toText(index) # "]";
    switch (Json.getAsText(tx, path)) {
      case (#ok p) { return p };            // plain string form
      case (#err _) {
        switch (Json.getAsText(tx, path # ".pubkey")) {
          case (#ok p) { return p };        // object form {pubkey,...}
          case (#err _) { return "" };
        };
      };
    };
  };

  // Resolve one element of an instruction's `accounts` array to its pubkey.
  // In `getTransaction` jsonParsed the shape differs by instruction position:
  //   - top-level instructions: `accounts` is an array of PUBKEY STRINGS
  //   - inner instructions:     `accounts` is an array of INDICES into
  //     `message.accountKeys` (and there is no `programId` string, only
  //     `programIdIndex`)
  // The binary-level Go reference (`CompiledInstruction.Accounts`) is always
  // indices; jsonParsed is not, so decode either form. (An index-only read
  // would mis-resolve top-level accounts and silently drop the transfer.)
  func resolveAccountPubkey(tx : Json.Json, acc : Json.Json) : Text {
    switch (Json.getAsText(acc, "")) {
      case (#ok pk) { pk }; // top-level: already a pubkey string
      case (#err _) {
        switch (Json.getAsNat(acc, "")) {
          case (#ok idx) { accountPubkey(tx, idx) }; // inner: index into accountKeys
          case (#err _) { "" };
        };
      };
    };
  };

  // flatten top-level instructions + inner instructions into one array.
  // (getTransaction / getBlock jsonParsed both shape a tx as {transaction, meta}.)
  func allInstructions(tx : Json.Json) : [Json.Json] {
    let out = List.empty<Json.Json>();
    switch (Json.getAsArray(tx, "transaction.message.instructions")) {
      case (#ok arr) { for (i in arr.vals()) { out.add(i) } };
      case (#err _) {};
    };
    switch (Json.getAsArray(tx, "meta.innerInstructions")) {
      case (#ok groups) {
        for (g in groups.vals()) {
          switch (Json.getAsArray(g, "instructions")) {
            case (#ok arr) { for (i in arr.vals()) { out.add(i) } };
            case (#err _) {};
          };
        };
      };
      case (#err _) {};
    };
    List.toArray(out);
  };

  // upsert: insert when unseen; refresh the stored slot when it advances, so
  // confirmation counting stays correct. `amount`/`to`/`asset` never change for
  // a fixed dedup key, only the height does.
  func recordDeposit(d : Types.Deposit) {
    if (d.amountRaw == 0) { return };
    switch (Map.get(deposits, Text.compare, d.dedupKey)) {
      case (null) {
        if (Map.get(confirmedKeys, Text.compare, d.dedupKey) == null) {
          Map.add(deposits, Text.compare, d.dedupKey, {
            signature = d.signature;
            slot = d.slot;
            asset = d.asset;
            token = d.token;
            from = d.from;
            to = d.to;
            amountRaw = d.amountRaw;
            blockHeight = d.slot;
            confirmations = 0;
            dedupKey = d.dedupKey;
          });
        };
      };
      case (?existing) {
        if (d.blockHeight > existing.blockHeight) {
          Map.add(deposits, Text.compare, d.dedupKey, { existing with blockHeight = d.blockHeight });
        };
      };
    };
  };

  func transferToDeposit(t : Types.Transfer) : Types.Deposit {
    {
      signature = t.signature;
      slot = t.slot;
      asset = t.asset;
      token = t.token;
      from = t.from;
      to = t.to;
      amountRaw = t.amountRaw;
      blockHeight = t.slot;
      confirmations = 0;
      dedupKey = t.dedupKey;
    };
  };

  // move deposits that reached CONFIRMED_SLOTS into depositsConfirmed; refresh
  // confirmations for the rest
  func confirmDeposits(tip : Nat) {
    let moved = List.empty<Types.Deposit>();
    let movedKeys = List.empty<Text>();
    let toRefresh = List.empty<(Text, Types.Deposit)>();
    for ((dk, d) in Map.entries(deposits)) {
      let confirmations = if (tip > d.blockHeight) { tip - d.blockHeight + 1 } else { 0 };
      if (confirmations >= Constants.CONFIRMED_SLOTS) {
        moved.add({ d with confirmations = confirmations });
        movedKeys.add(dk);
      } else if (confirmations != d.confirmations) {
        toRefresh.add((dk, { d with confirmations = confirmations }));
      };
    };
    // delete archived entries AFTER the iteration — mutating the map mid-iteration is unsafe
    for (dk in List.toArray(movedKeys).vals()) {
      ignore Map.delete(deposits, Text.compare, dk);
      Map.add(confirmedKeys, Text.compare, dk, ());
    };
    for ((dk, d) in List.toArray(toRefresh).vals()) {
      Map.add(deposits, Text.compare, dk, d);
    };
    let movedArr = List.toArray(moved);
    if (movedArr.size() > 0) {
      let combined = List.fromArray<Types.Deposit>(depositsConfirmed);
      List.append(combined, moved);
      depositsConfirmed := List.toArray(combined);
    };
  };

  // core refresh for one watched address: fetch new finalized signatures since
  // its cursor, resolve and parse each, record deposits, advance the cursor.
  func doRefresh(addr : Text) : async () {
    switch (Map.get(lastSignature, Text.compare, addr)) {
      case null {
        // first refresh: seed the cursor with the newest finalized signature and
        // do NOT process history (avoids crediting ancient deposits as new). The
        // backend should refresh promptly after registration so the window
        // between registration and first refresh stays empty.
        switch (await getSigs(addr, null, null, 1)) {
          case (?sigs) { if (sigs.size() > 0) { Map.add(lastSignature, Text.compare, addr, sigs[0].0) } };
          case null {};
        };
      };
      case (?cur) {
        // fetch ALL new signatures (newer than cur), paging back with `before`;
        // abort the whole refresh on RPC error so the cursor isn't advanced past
        // signatures we never actually fetched
        let collected = List.empty<(Text, Nat)>();
        var beforeSig : ?Text = null;
        var aborted = false;
        var done = false;
        var pages = 0;
        while (not done and not aborted and pages < Constants.MAX_SIG_PAGES) {
          switch (await getSigs(addr, ?cur, beforeSig, Constants.SIG_LIMIT)) {
            case null { aborted := true };
            case (?sigs) {
              if (sigs.size() == 0) { done := true }
              else {
                for (s in sigs.vals()) { collected.add(s) };
                pages += 1;
                if (sigs.size() < Constants.SIG_LIMIT) { done := true }
                else { beforeSig := ?sigs[sigs.size() - 1].0 };
              };
            };
          };
        };
        if (aborted) { return };

        // process oldest-first (collected is newest-first); on a getTransaction
        // failure, stop and keep the cursor at the newest successfully processed
        // signature so the failed one (and anything newer) is retried next time
        let arr = List.toArray(collected);
        var lastOk : ?Text = null;
        var stop = false;
        var i = arr.size();
        while (i > 0 and not stop) {
          i -= 1;
          let (sig, _slotHint) = arr[i];
          switch (await getTx(sig)) {
            case (?(txSlot, txJson)) { processTxJson(txJson, txSlot); lastOk := ?sig };
            case null { stop := true };
          };
        };
        switch (lastOk) { case (?s) { Map.add(lastSignature, Text.compare, addr, s) }; case null {} };

        // archive finalized deposits (fetched txs are finalized → deep already)
        confirmDeposits(await latestSlot());
      };
    };
  };

  // PUBLIC ENTRY (controller): refresh one SOL owner address's deposits from the
  // chain — both its native SOL transfers AND every SPL token transfer to its
  // associated token accounts (ATA), derived in-canister from (owner, mint).
  // `addr` must be a registered SOL deposit address (watchedAddresses).
  public shared (msg) func refreshAddressTx(addr : Text) : async () {
    requireController(msg.caller);
    if (Map.get(watchedAddresses, Text.compare, addr) == null) {
      Runtime.trap("Address is not a watched SOL deposit address");
    };
    if (Map.get(refreshing, Text.compare, addr) != null) { return };
    Map.add(refreshing, Text.compare, addr, true);

    // 1) native SOL transfers to the owner wallet
    await doRefresh(addr);

    // 2) SPL transfers to each (owner, mint) ATA — derived, never stored
    for ((mint, program) in Map.entries(watchedTokens)) {
      switch (Ata.ataAddress(addr, mint, program)) {
        case (?ata) { await doRefresh(ata) };
        case null { /* malformed mint/program — skip */ };
      };
    };

    ignore Map.delete(refreshing, Text.compare, addr);
  };

  system func postupgrade() {
    Map.clear(refreshing);
    // backfill the archive-key set from existing confirmed deposits so a
    // re-fetched transfer isn't archived twice right after an upgrade
    for (d in depositsConfirmed.vals()) {
      Map.add(confirmedKeys, Text.compare, d.dedupKey, ());
    };
  };

  system func inspect({ caller : Principal }) : Bool {
    if (Principal.isController(caller)) { return true };
    not Principal.isAnonymous(caller);
  };
};
