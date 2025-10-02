{.used.}
import results
import ../../libp2p/protocols/kademlia/[kademlia, keys]

type PermissiveValidator* = ref object of EntryValidator
method isValid*(self: PermissiveValidator, key: Key, val: seq[byte]): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method isValid(self: RestrictiveValidator, key: Key, val: seq[byte]): bool =
  false

type CandSelector* = ref object of EntrySelector
method select*(
    self: CandSelector, key: Key, values: seq[seq[byte]]
): Result[int, string] =
  return ok(0)

type OthersSelector* = ref object of EntrySelector
method select*(
    self: OthersSelector, key: Key, values: seq[seq[byte]]
): Result[int, string] =
  if values.len == 0:
    return err("no values were given")
  if values.len == 1:
    return ok(0)
  ok(1)
