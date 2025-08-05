{.used.}
import ../../libp2p/protocols/kademlia/dhttypes

type PermissiveValidator* = ref object of EntryValidator
method validate*(self: PermissiveValidator, cand: EntryCandidate): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method validate(self: RestrictiveValidator, cand: EntryCandidate): bool =
  false

type ApatheticSelector* = ref object of EntrySelector
method select*(
    self: ApatheticSelector, cand: RecordVal, others: seq[RecordVal]
): RecordVal =
  return cand
