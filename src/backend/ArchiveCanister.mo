// ArchiveCanister.mo — append-only archive for permanent user history.
//
// Spawned and fed by the main canister (docs/archive-design.md). Phase A′:
// a single "sidecar" instance; sealed-chain growth (spawn-ahead, routing
// fan-out) is Phase B. The main canister is the `owner`: only it may append,
// and as the controller it deletes the sidecar wholesale on a sim reset —
// that is the reset story, so this actor needs no wipe entry point.
//
// Storage: events arrive in strict global-seq order via appendBatch
// (idempotent on replays — re-shipped batches after an unknown-outcome call
// are skipped by seq) and are stored as length-delimited candid blobs in a
// stable Region, so the heap holds only the offset indexes. Candid encoding
// keeps records self-describing: fields added later (e.g. the Phase-D hash
// chain) decode against old blobs as long as they're `opt`.
//
// Queries are public by design (decision #4, 2026-06-10): getMyEvents is the
// caller's own history (tax view), getEventsRange is the public tape — fills
// are already public on the hot canister's tape, so the archive is just its
// durable continuation.

import Principal "mo:core/Principal";
import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Order "mo:core/Order";
import Region "mo:core/Region";
import Cycles "mo:core/Cycles";
import CertifiedData "mo:core/CertifiedData";
import Blob "mo:core/Blob";
import Prim "mo:⛔"; // rts_memory_size / rts_heap_size for the Stats → Archive panel
import Types "lib/Types";
import EventChain "lib/EventChain";

persistent actor class Archive(owner : Principal) {

  let data = Region.new();
  var dataEnd : Nat64 = 0;     // bytes written so far
  var firstSeq : ?Nat = null;  // seq of the first stored event
  var nextExpected : Nat = 0;  // next seq accepted (= count stored + firstSeq)

  // ── Tamper-evidence chain (Phase D) ──────────────────────────────
  // The archive re-derives the hash chain as events arrive: each stored
  // event's recomputed hash must equal the NEXT event's prevHash, or the
  // batch is refused — corruption cannot enter silently. The running head
  // is pushed into certified_data, so any reader can (a) trust the head via
  // the IC certificate and (b) verify the events beneath it offline with
  // EventChain's canonical form. chainStartSeq marks where verification
  // begins: events shipped before the chain existed (or before this archive
  // learned the code) stay stored but unverifiable.
  var chainHead : ?Blob = null;
  var chainStartSeq : ?Nat = null;

  // Offset indexes into `data`. The global index is the public tape
  // (position = seq − firstSeq); the per-user index is the tax view.
  let globalIndex = List.empty<(Nat64, Nat)>();
  let userIndex = Map.empty<Text, List.List<(Nat64, Nat)>>();

  // Deposit/withdrawal index — a kind-filtered slice of the global tape, so the
  // exchange can serve "all users' deposits & withdrawals" (a public money-flow
  // ledger) without a full per-query scan of millions of events. Built by
  // advancing `dwCursor` through globalIndex IN ORDER, so dwIndex stays
  // seq-ascending and its tail is the newest D/W. Populated incrementally on
  // append + by the controller-driven backfill (backfillDwIndex) for the events
  // that predate this index.
  let dwIndex = List.empty<(Nat64, Nat)>();
  var dwCursor : Nat = 0;   // globalIndex positions [0, dwCursor) already scanned into dwIndex

  // True iff `data` can hold `needed` bytes. Region.grow signals failure by
  // RETURNING 0xFFFF_FFFF_FFFF_FFFF — the build's --max-stable-pages cap, or
  // the IC refusing this canister more memory — it does not trap. That result
  // must be checked: ignoring it lets the next storeBlob trap "range out of
  // bounds" and wedge the shipper (July 2026 subnet incident at 4 GiB).
  func ensureCapacity(needed : Nat64) : Bool {
    let have = Region.size(data) * 65536;
    if (needed > have) {
      let before = Region.grow(data, (needed - have + 65535) / 65536);
      if (before == 0xFFFF_FFFF_FFFF_FFFF) { return false };
    };
    true
  };

  // False = at capacity; nothing (region bytes, indexes, cursor) is mutated.
  func store(e : Types.UserEvent) : Bool {
    let blob = to_candid (e);
    let len = blob.size();
    if (not ensureCapacity(dataEnd + Nat64.fromNat(len))) { return false };
    Region.storeBlob(data, dataEnd, blob);
    let entry = (dataEnd, len);
    List.add(globalIndex, entry);
    let key = Principal.toText(e.user);
    let lst = switch (Map.get(userIndex, Text.compare, key)) {
      case (?l) { l };
      case null {
        let l = List.empty<(Nat64, Nat)>();
        Map.add(userIndex, Text.compare, key, l);
        l
      };
    };
    List.add(lst, entry);
    dataEnd += Nat64.fromNat(len);
    true
  };

  func load(entry : (Nat64, Nat)) : ?Types.UserEvent {
    from_candid (Region.loadBlob(data, entry.0, entry.1));
  };

  func loadAt(lst : List.List<(Nat64, Nat)>, i : Nat) : ?Types.UserEvent {
    switch (List.get(lst, i)) {
      case (?entry) { load(entry) };
      case null { null };
    };
  };

  // Advance the deposit/withdrawal index by up to `maxScan` more globalIndex
  // positions (in seq order), appending the offset of every #deposit-kind event
  // (covers both deposits and withdrawals). Returns positions scanned this call.
  // Used both for live catch-up (small, per append) and the controller backfill
  // (large chunks over the pre-index backlog).
  func dwScan(maxScan : Nat) : Nat {
    let n = List.size(globalIndex);
    let stop = Nat.min(dwCursor + maxScan, n);
    var i = dwCursor;
    while (i < stop) {
      switch (List.get(globalIndex, i)) {
        case (?entry) {
          switch (load(entry)) {
            case (?e) { switch (e.kind) { case (#deposit _) { List.add(dwIndex, entry) }; case _ {} } };
            case null {};
          };
        };
        case null {};
      };
      i += 1;
    };
    let scanned : Nat = stop - dwCursor;
    dwCursor := stop;
    scanned
  };

  // Append a strictly-ordered batch. Replays of already-stored seqs are
  // skipped (the shipper re-sends on unknown outcomes); a gap is an error —
  // the shipper never skips ahead, so a gap means a bug, and storing around
  // it would corrupt the position arithmetic.
  //
  // Chain enforcement: once this archive holds a chain head, every stored
  // event's prevHash must equal it (and the head advances to the event's
  // recomputed hash) — a batch that breaks the link is REFUSED before any of
  // its remainder is stored. The first event ever seen anchors the chain
  // whatever its prevHash (pre-chain deployments / an archive upgraded after
  // main started chaining): links before the anchor are simply unverifiable.
  //
  // Capacity: #full(n) means "stored through n−1 and can take NO more" — the
  // stable region hit its cap mid-batch. The prefix is acked exactly like #ok
  // (the shipper must not re-send it); the shipper's response is to seal this
  // archive and roll to a fresh successor.
  public shared (msg) func appendBatch(events : [Types.UserEvent]) : async { #ok : Nat; #full : Nat; #err : Text } {
    if (msg.caller != owner) { return #err("not the owning canister") };
    var full = false;
    label ship for (e in events.vals()) {
      // A SUCCESSOR archive in the Phase-B chain starts mid-tape: the very
      // first event it ever sees defines its base seq (archive_0 gets 0; the
      // second archive gets wherever the previous one sealed).
      if (firstSeq == null) { nextExpected := e.seq };
      if (e.seq < nextExpected) {
        // replay of an acked event — already stored, skip
      } else if (e.seq > nextExpected) {
        return #err("seq gap: got " # Nat.toText(e.seq) # ", expected " # Nat.toText(nextExpected));
      } else {
        switch (chainHead) {
          case (?h) {
            if (e.prevHash != ?h) {
              return #err("chain break at seq " # Nat.toText(e.seq) # " — prevHash does not match the stored head");
            };
          };
          case null {};
        };
        if (not store(e)) {
          // Region at capacity — none of THIS event was written (store checks
          // before mutating). Ack the stored prefix as #full below; the chain
          // head/anchor state only ever reflects fully-stored events.
          full := true;
          break ship;
        };
        if (chainHead == null) { chainStartSeq := ?e.seq };   // anchor point
        if (firstSeq == null) { firstSeq := ?e.seq };
        chainHead := ?EventChain.hash(e);
        nextExpected += 1;
      };
    };
    // Publish the head into the system certificate so readers can trust it
    // (32 bytes — exactly what certified_data holds).
    switch (chainHead) { case (?h) { CertifiedData.set(h) }; case null {} };
    // Keep the D/W index current. Once the backfill has caught the cursor up to
    // the tape end, this scans exactly the batch just stored; while a backlog
    // remains it chips away (the controller backfill does the bulk).
    ignore dwScan(events.size() + 16);
    if (full) { return #full(nextExpected) };
    #ok(nextExpected);
  };

  // The certified chain head: `certificate` (in a query call) proves the
  // subnet vouches for `headHash` as this canister's certified data. A
  // reader verifies the certificate, then re-derives the chain over fetched
  // events (EventChain canonical form) up to the head. headSeq = the last
  // chained event; links verify from chainStartSeq forward.
  public query func getCertifiedHead() : async {
    headHash      : ?Blob;
    headSeq       : ?Nat;    // seq of the event the head hash covers
    chainStartSeq : ?Nat;
    certificate   : ?Blob;
  } {
    {
      headHash = chainHead;
      headSeq = if (nextExpected == 0) { null } else { ?(nextExpected - 1) };
      chainStartSeq;
      certificate = CertifiedData.getCertificate();
    };
  };

  // Recompute + verify the chain over a stored range (bounded per call —
  // page a full audit). Checks BOTH directions of integrity: each event's
  // recomputed hash equals its successor's prevHash. `ok=false` pinpoints
  // the first broken seq. Anyone may call; the stronger, trustless variant
  // is the same computation done client-side under the certified head.
  public query func verifyChain(fromSeq : Nat, limit : Nat) : async {
    checked : Nat; ok : Bool; brokenAt : ?Nat; nextSeq : ?Nat;
  } {
    let base = switch (firstSeq) { case (?f) { f }; case null { return { checked = 0; ok = true; brokenAt = null; nextSeq = null } } };
    let start = switch (chainStartSeq) { case (?s) { Nat.max(fromSeq, s) }; case null { return { checked = 0; ok = true; brokenAt = null; nextSeq = null } } };
    if (start >= nextExpected) { return { checked = 0; ok = true; brokenAt = null; nextSeq = null } };
    let capped = Nat.min(limit, 10_000);
    var s = start;
    var prev : ?Types.UserEvent = null;
    var checked = 0;
    while (s < nextExpected and checked < capped) {
      switch (loadAt(globalIndex, s - base)) {
        case (?e) {
          switch (prev) {
            case (?p) {
              if (e.prevHash != ?EventChain.hash(p)) {
                return { checked; ok = false; brokenAt = ?e.seq; nextSeq = null };
              };
            };
            case null {};
          };
          prev := ?e;
        };
        case null { return { checked; ok = false; brokenAt = ?s; nextSeq = null } };
      };
      checked += 1;
      s += 1;
    };
    { checked; ok = true; brokenAt = null; nextSeq = if (s < nextExpected) { ?s } else { null } };
  };

  // The caller's own events, newest-first. `offset` counts back from the
  // newest (0 = most recent page); pages cap at 200.
  public query (msg) func getMyEvents(offset : Nat, limit : Nat) : async {
    events : [Types.UserEvent];
    total  : Nat;
  } {
    let lst = switch (Map.get(userIndex, Text.compare, Principal.toText(msg.caller))) {
      case (?l) { l };
      case null { return { events = []; total = 0 } };
    };
    let total = List.size(lst);
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    // Int arithmetic — Nat subtraction would trap when offset ≥ total.
    var idx : Int = (total : Int) - 1 - (offset : Int);
    while (idx >= 0 and List.size(result) < capped) {
      switch (loadAt(lst, Int.abs(idx))) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      idx -= 1;
    };
    { events = Iter.toArray(List.values(result)); total };
  };

  // Events across a SET of principals, newest-first, paged. Lets a user see
  // their full margin history: spot fills archive under the human principal,
  // but margin fills archive under the POOL principals — the caller passes
  // their human + pool principals and gets the merged, paginated timeline.
  //
  // OWNER-GATED: only the exchange canister (the archive owner) may call this
  // directly. A user reaches their OWN history through the exchange's
  // getMyArchivedEvents composite query, which resolves the caller's principals
  // and federates here AS the owner. This closes the targeted vector — arbitrary
  // by-principal lookups (leaderboard → rival's principal → position → liq
  // price). The public whole-tape reads (getEventsRange, getDepositWithdrawals)
  // stay open: the chain verifier + PoR need them, and they carry no easy
  // per-human attribution index. Region offset is monotonic with global seq, so
  // sorting the gathered index entries by offset descending = newest-first.
  public query (msg) func getEventsForPrincipals(principals : [Principal], offset : Nat, limit : Nat) : async {
    events : [Types.UserEvent];
    total  : Nat;
  } {
    if (not Principal.equal(msg.caller, owner)) { return { events = []; total = 0 } };
    let entries = List.empty<(Nat64, Nat)>();
    for (p in principals.vals()) {
      switch (Map.get(userIndex, Text.compare, Principal.toText(p))) {
        case (?l) { for (e in List.values(l)) { List.add(entries, e) } };
        case null {};
      };
    };
    let arr = Iter.toArray(List.values(entries));
    let sorted = Array.sort(arr, func(a : (Nat64, Nat), b : (Nat64, Nat)) : Order.Order { Nat64.compare(b.0, a.0) });
    let total = sorted.size();
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var i = offset;
    while (i < total and List.size(result) < capped) {
      switch (load(sorted[i])) { case (?e) { List.add(result, e) }; case null {} };
      i += 1;
    };
    { events = Iter.toArray(List.values(result)); total };
  };

  // Public tape: events by global seq, ascending from `startSeq`.
  public query func getEventsRange(startSeq : Nat, limit : Nat) : async [Types.UserEvent] {
    let base = switch (firstSeq) { case (?f) { f }; case null { return [] } };
    if (startSeq < base or startSeq >= nextExpected) { return [] };
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var s = startSeq;
    while (s < nextExpected and List.size(result) < capped) {
      switch (loadAt(globalIndex, s - base)) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      s += 1;
    };
    Iter.toArray(List.values(result));
  };

  // Self-reported metrics — powers the dashboard's archive card and the
  // Phase-B cycle top-up watermarks (cheaper than management-canister
  // status calls, and callable by anyone).
  public query func stats() : async {
    firstSeq   : ?Nat;
    nextSeq    : Nat;
    eventCount : Nat;
    bytes      : Nat64;   // durable event data in the stable Region
    users      : Nat;
    cycles     : Nat;
    memorySizeBytes : Nat; // total wasm memory (heap + code + stable pages)
    heapLiveBytes   : Nat; // live heap (the offset indexes; the events live in the Region)
    chainStartSeq : ?Nat;  // links verify from here forward (null = no chain yet)
    chainHead     : ?Blob; // running chain hash (also in certified_data)
  } {
    {
      firstSeq;
      nextSeq    = nextExpected;
      eventCount = List.size(globalIndex);
      bytes      = dataEnd;
      users      = Map.size(userIndex);
      cycles     = Cycles.balance();
      memorySizeBytes = Prim.rts_memory_size();
      heapLiveBytes   = Prim.rts_heap_size();
      chainStartSeq;
      chainHead;
    };
  };

  // Recent deposits & withdrawals across ALL users, newest-first. Public by
  // design (the money-flow ledger — funds in/out of the exchange are auditable).
  // Reads the kind-filtered dwIndex, so it's bounded regardless of tape size.
  // Coverage grows as backfillDwIndex catches the index up over the backlog.
  public query func getDepositWithdrawals(offset : Nat, limit : Nat) : async [Types.UserEvent] {
    let total = List.size(dwIndex);
    let capped = if (limit > 200) { 200 } else { limit };
    let result = List.empty<Types.UserEvent>();
    var idx : Int = (total : Int) - 1 - (offset : Int);   // newest-first
    while (idx >= 0 and List.size(result) < capped) {
      switch (loadAt(dwIndex, Int.abs(idx))) {
        case (?e) { List.add(result, e) };
        case null {};
      };
      idx -= 1;
    };
    Iter.toArray(List.values(result));
  };

  // Owner-only (the controlling exchange canister): advance the D/W index over
  // the pre-index backlog. Call repeatedly until `done`; each call scans up to
  // `maxScan` tape positions. Idempotent and monotonic (the cursor only moves
  // forward), so re-runs are safe.
  public shared (msg) func backfillDwIndex(maxScan : Nat) : async {
    scanned : Nat; cursor : Nat; total : Nat; dwCount : Nat; done : Bool;
  } {
    if (msg.caller != owner) {
      return { scanned = 0; cursor = dwCursor; total = List.size(globalIndex); dwCount = List.size(dwIndex); done = dwCursor >= List.size(globalIndex) };
    };
    let scanned = dwScan(maxScan);
    { scanned; cursor = dwCursor; total = List.size(globalIndex); dwCount = List.size(dwIndex); done = dwCursor >= List.size(globalIndex) };
  };
};
