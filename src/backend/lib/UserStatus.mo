// UserStatus.mo — pure helpers that maintain the per-user version
// counters, deposit history, and adjustment history.
//
// Lives in lib/ (not mixins/) because multiple mixins need to call
// these from different concerns (trade flow bumps version, deposit
// flow appends to deposit history, etc.). Mixins are scope-isolated;
// shared helpers must come from lib modules.
//
// Every function takes the relevant Map as its first parameter, so
// no implicit state is owned here.

import List "mo:core/List";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import SafeMath "SafeMath";
import Types "Types";
import OrderBook "OrderBook";

module {

  public type UserStatusMap = Map.Map<Text, Types.UserStatus>;
  public type DepositMap = Map.Map<Text, List.List<Types.DepositRecord>>;
  public type AdjustmentMap = Map.Map<Text, List.List<Types.OrderAdjustment>>;
  public type ClosedOrderMap = Map.Map<Text, List.List<Types.ClosedOrderRecord>>;

  // ── Per-user history STORAGE caps ───────────────────────────────
  // The views cap lower (200); these bound the heap. Unbounded per-user
  // append-forever lists were part of the 2026-06-10 heap incident, so every
  // history list now trims on append: once size passes TRIM_AT, rebuild
  // keeping the newest KEEP (amortised — the O(KEEP) copy runs once per
  // TRIM_AT−KEEP appends, the same pattern as the trade-list caps in main.mo).
  let DEPOSITS_KEEP          = 500;   let DEPOSITS_TRIM_AT      = 600;
  let ADJUSTMENTS_KEEP       = 1_000; let ADJUSTMENTS_TRIM_AT   = 1_200;
  let CLOSED_ORDERS_KEEP     = 500;   let CLOSED_ORDERS_TRIM_AT = 600;

  func trimmed<T>(lst : List.List<T>, keep : Nat) : List.List<T> {
    let n = List.size(lst);
    let out = List.empty<T>();
    for (x in List.range(lst, SafeMath.subOrZero(n, keep), n)) { List.add(out, x) };
    out
  };

  func getOrCreate<T>(map : Map.Map<Text, List.List<T>>, key : Text) : List.List<T> {
    switch (Map.get(map, Text.compare, key)) {
      case (?l) { l };
      case null {
        let l = List.empty<T>();
        Map.add(map, Text.compare, key, l);
        l
      };
    };
  };

  // Append one deposit record to a user's history (capped).
  public func appendDeposit(
    userDeposits : DepositMap,
    user : Principal,
    record : Types.DepositRecord,
  ) {
    let key = Principal.toText(user);
    let lst = getOrCreate(userDeposits, key);
    List.add(lst, record);
    if (List.size(lst) > DEPOSITS_TRIM_AT) {
      Map.add(userDeposits, Text.compare, key, trimmed(lst, DEPOSITS_KEEP));
    };
  };

  // Append a batch of order-adjustment entries to a user's history (capped).
  public func appendAdjustments(
    userAdjustments : AdjustmentMap,
    user : Principal,
    adjs : [Types.OrderAdjustment],
  ) {
    if (adjs.size() == 0) return;
    let key = Principal.toText(user);
    let lst = getOrCreate(userAdjustments, key);
    for (a in adjs.vals()) { List.add(lst, a) };
    if (List.size(lst) > ADJUSTMENTS_TRIM_AT) {
      Map.add(userAdjustments, Text.compare, key, trimmed(lst, ADJUSTMENTS_KEEP));
    };
  };

  // Append one closed-order record to a user's history (capped). Written by
  // the reaper exactly once per closed order (first sight marks + appends,
  // the next sweep deletes the hot record); read by getMyClosedOrders /
  // the Account page "Recently Closed Orders" box.
  public func appendClosedOrder(
    userClosedOrders : ClosedOrderMap,
    user : Principal,
    record : Types.ClosedOrderRecord,
  ) {
    let key = Principal.toText(user);
    let lst = getOrCreate(userClosedOrders, key);
    List.add(lst, record);
    if (List.size(lst) > CLOSED_ORDERS_TRIM_AT) {
      Map.add(userClosedOrders, Text.compare, key, trimmed(lst, CLOSED_ORDERS_KEEP));
    };
  };

  // Bump the user's version counter; keep lastTradeTime unchanged.
  // Used when the user's openOrderCount or balances change but no
  // trade actually fired (e.g. limit order placed without crossing).
  public func bumpVersion(
    userStatuses : UserStatusMap,
    orderStore : OrderBook.OrderStore,
    user : Principal,
  ) {
    let key = Principal.toText(user);
    let current = switch (Map.get(userStatuses, Text.compare, key)) {
      case (?s) { s };
      case null { { version = 0; lastTradeTime = 0 : Int; openOrderCount = 0 } };
    };
    let openCount = OrderBook.getUserOpenOrders(orderStore, user).size();
    Map.add(userStatuses, Text.compare, key, {
      version = current.version + 1;
      lastTradeTime = current.lastTradeTime;
      openOrderCount = openCount;
    });
  };

  // Bump the user's version counter AND advance lastTradeTime if the
  // supplied tradeTime is newer than the previously-recorded value.
  // Used after trades fire so the frontend's user-trade-history poll
  // invalidates correctly.
  public func bumpVersionWithTrade(
    userStatuses : UserStatusMap,
    orderStore : OrderBook.OrderStore,
    user : Principal,
    tradeTime : Int,
  ) {
    let key = Principal.toText(user);
    let current = switch (Map.get(userStatuses, Text.compare, key)) {
      case (?s) { s };
      case null { { version = 0; lastTradeTime = 0 : Int; openOrderCount = 0 } };
    };
    let openCount = OrderBook.getUserOpenOrders(orderStore, user).size();
    Map.add(userStatuses, Text.compare, key, {
      version = current.version + 1;
      lastTradeTime = if (tradeTime > current.lastTradeTime) { tradeTime } else { current.lastTradeTime };
      openOrderCount = openCount;
    });
  };

  // Read a user's status (or a zero default if not yet present).
  public func get(
    userStatuses : UserStatusMap,
    user : Principal,
  ) : Types.UserStatus {
    switch (Map.get(userStatuses, Text.compare, Principal.toText(user))) {
      case (?s) { s };
      case null { { version = 0; lastTradeTime = 0 : Int; openOrderCount = 0 } };
    };
  };
};
