/// The schema document returned by `schema()`. Plain types + a minimal
/// hand-rolled JSON serialiser (no dependency on a JSON encoder).
///
/// Field types are carried as `Text` tags (`"Nat"`, `"Text"`, ...).
/// A structural type table can replace this once nested records and
/// variants need richer descriptions.

import Bool  "mo:core/Bool";
import Char  "mo:core/Char";
import Float "mo:core/Float";
import Int   "mo:core/Int";
import Iter  "mo:core/Iter";
import Nat   "mo:core/Nat";
import Text  "mo:core/Text";
import Types "Types";

module {

  public type Role = Types.FieldRole;

  /// `domain`, when present, lists the distinct values the field can hold —
  /// e.g. the arms of a variant rendered as text. Lets a client offer exact
  /// filter values without a probe query. `null` means "unbounded / unknown".
  public type FieldDecl  = { name : Text; typeName : Text; role : Role; domain : ?[Types.Value] };
  public type EntityDecl = { name : Text; typeName : Text; primaryKey : Text; fields : [FieldDecl] };
  public type Document   = { entities : [EntityDecl] };

  public func toJson(doc : Document) : Text =
    "{\"entities\":[" # doc.entities.values().map(entityToJson).join(",") # "]}";

  func entityToJson(e : EntityDecl) : Text {
    let fields = e.fields.values().map(fieldToJson).join(",");
    "{\"name\":\""        # escape(e.name)
    # "\",\"typeName\":\""   # escape(e.typeName)
    # "\",\"primaryKey\":\"" # escape(e.primaryKey)
    # "\",\"fields\":[" # fields # "]}"
  };

  func fieldToJson(f : FieldDecl) : Text {
    let role = switch (f.role) {
      case (#payload)     { "\"payload\"" };
      case (#owner)       { "\"owner\"" };
      case (#hidden)      { "\"hidden\"" };
      case (#edge { to }) { "{\"edge\":{\"to\":\"" # escape(to) # "\"}}" };
    };
    let values = switch (f.domain) {
      case null   { "" };
      case (?vs)  { ",\"values\":[" # vs.values().map(valueToJson).join(",") # "]" };
    };
    "{\"name\":\""       # escape(f.name)
    # "\",\"typeName\":\"" # escape(f.typeName)
    # "\",\"role\":" # role # values # "}"
  };

  /// Serialise a scalar `Value` as a JSON literal — used for `domain`
  /// arrays. Text is quoted and escaped; numbers/bools/null are bare.
  func valueToJson(v : Types.Value) : Text = switch v {
    case (#null_)   { "null" };
    case (#bool b)  { Bool.toText(b) };
    case (#nat n)   { Nat.toText(n) };
    case (#int i)   { Int.toText(i) };
    case (#float f) { Float.toText(f) };
    case (#text t)  { "\"" # escape(t) # "\"" };
  };

  /// Minimal escaping for identifier-shaped strings. Swap in a full
  /// encoder once user data flows through here.
  func escape(s : Text) : Text {
    var out = "";
    for (c in s.chars()) {
      out := out # (switch c {
        case '\\' { "\\\\" };
        case '\"' { "\\\"" };
        case '\n' { "\\n"  };
        case '\r' { "\\r"  };
        case '\t' { "\\t"  };
        case _    { c.toText() };
      });
    };
    out
  };

};
