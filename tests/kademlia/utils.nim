{.used.}
import ../../libp2p/protocols/kademlia/dhttypes

type PermissiveValidator* = ref object of EntryValidator
method validate*(self: PermissiveValidator, cand: EntryCandidate): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method validate(self: RestrictiveValidator, cand: EntryCandidate): bool =
  false

type CandSelector* = ref object of EntrySelector
method select*(self: CandSelector, cand: RecordVal, others: seq[RecordVal]): RecordVal =
  return cand

type OthersSelector* = ref object of EntrySelector
method select*(
    self: OthersSelector, cand: RecordVal, others: seq[RecordVal]
): RecordVal =
  return
    if others.len == 0:
      cand
    else:
      others[0]
