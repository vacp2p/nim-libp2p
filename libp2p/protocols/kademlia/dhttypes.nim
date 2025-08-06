import chronicles
import std/[tables, hashes]
import results

# TODO: make data formater for log-friendly form.

type EntryKey* = object
  data*: seq[byte]

type EntryVal* = object
  data*: seq[byte]

type TimeStamp* = object
  # Currently a string, because for some reason, that's what is chosen at the protobuf level
  # TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
  ts*: string

type EntryCandidate* = object
  key*: EntryKey
  value*: EntryVal

type ValidatedEntry* = object
  key*: EntryKey
  value*: EntryVal

type RecordVal* = object
  value*: EntryVal
  time*: TimeStamp

## Top tip: add chronicles logs to your implementation
type EntryValidator* = ref object of RootObj
method validate*(
    self: EntryValidator, entry: EntryCandidate
): bool {.base, raises: [], gcsafe.} =
  doAssert(false, "unimplimented base method")

type EntrySelector* = ref object of RootObj
method select*(
    self: EntrySelector, cand: RecordVal, others: seq[RecordVal]
): RecordVal {.base, raises: [], gcsafe.} =
  doAssert(false, "EntrySelection base not implemented")

# TODO: make library public, but hidden to users of library
proc take*(
    self: typedesc[ValidatedEntry], entry: sink EntryCandidate
): ValidatedEntry {.raises: [].} =
  ValidatedEntry(key: entry.key, value: entry.value)

type LocalTable* = object
  entries*: Table[EntryKey, RecordVal]

proc init*(self: typedesc[LocalTable]): LocalTable {.raises: [].} =
  LocalTable(entries: initTable[EntryKey, RecordVal]())

# TODO: make library public, but hidden to users of library
proc insert*(
    self: var LocalTable, value: sink ValidatedEntry, time: TimeStamp
) {.raises: [].} =
  debug "local table insertion", key = value.key.data, value = value.value.data
  self.entries[value.key] = RecordVal(value: value.value, time: time)
