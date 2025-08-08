{.used.}
import results
import ../../libp2p/protocols/kademlia/kademlia

type PermissiveValidator* = ref object of EntryValidator
method isValid*(self: PermissiveValidator, key: EntryKey, val: EntryValue): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method isValid(self: RestrictiveValidator, key: EntryKey, val: EntryValue): bool =
  false

type CandSelector* = ref object of EntrySelector
method select*(
    self: CandSelector, cand: EntryRecord, others: seq[EntryRecord]
): Result[EntryRecord, string] =
  return ok(cand)

type OthersSelector* = ref object of EntrySelector
method select*(
    self: OthersSelector, cand: EntryRecord, others: seq[EntryRecord]
): Result[EntryRecord, string] =
  return
    if others.len == 0:
      ok(cand)
    else:
      ok(others[0])
