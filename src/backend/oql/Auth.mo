/// Per-table authorization. Each entity declares a `TableAuth` level; at
/// query time `resolve(level, caller)` turns it into the read `Access` for
/// that caller:
///
///   #deny          — this caller may not read the entity at all
///   #unrestricted  — read every row of the entity
///   #scoped p      — read, but only rows the entity's owner check admits
///                    for principal `p` (see Entity.ownedBy/ownedByWith)
///
/// The levels:
///
///   #public_            — everyone (anonymous included) reads every row
///   #controllerOnly     — controllers read every row; everyone else denied
///   #scopedPerUser      — every non-anonymous caller (controllers included)
///                         is scoped to its own rows; anonymous denied
///   #controllerOrScoped — controllers read every row; other non-anonymous
///                         callers are scoped to their own rows; anonymous
///                         denied
///
/// The resolved scope threads per-entity into the executor and the schema
/// projection, so a caller never sees — directly or through a join — rows
/// an entity's level denies them.

import Principal "mo:core/Principal";

module {

  public type Access = {
    #deny;
    #unrestricted;
    #scoped : Principal;
  };

  /// The authorization level an entity is exposed at.
  public type TableAuth = {
    #public_;
    #controllerOnly;
    #scopedPerUser;
    #controllerOrScoped;
  };

  /// Resolve an entity's level against a caller into a read `Access`.
  public func resolve(level : TableAuth, caller : Principal) : Access =
    switch level {
      case (#public_) { #unrestricted };
      case (#controllerOnly) {
        if (caller.isController()) #unrestricted else #deny;
      };
      case (#scopedPerUser) {
        if (caller.isAnonymous()) #deny else #scoped caller;
      };
      case (#controllerOrScoped) {
        if (caller.isController()) #unrestricted
        else if (caller.isAnonymous()) #deny
        else #scoped caller;
      };
    };

};
