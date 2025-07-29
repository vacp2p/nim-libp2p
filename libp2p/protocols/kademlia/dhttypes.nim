import chronicles
import std/[tables, hashes]
import results

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
  val*: EntryVal
  time*: TimeStamp

type ValidatedEntry* = object
  key*: EntryKey
  val*: EntryVal
  time*: TimeStamp

type EntryValidator* = ref object of RootObj
method validate*(
    self: EntryValidator, key: EntryKey, val: EntryVal
): bool {.base, raises: [], gcsafe.} =
  discard

# get a validated entry from a app defined validator and 

type RecordVal* = object
  value: EntryVal
  time: TimeStamp

type LocalTable* = object
  entries*: Table[EntryKey, (EntryVal, TimeStamp)]

proc init*(self: typedesc[LocalTable]): LocalTable {.raises: [].} =
  LocalTable(entries: initTable[EntryKey, (EntryVal, TimeStamp)]())

proc insert*(self: var LocalTable, val: sink ValidatedEntry) =
  info "inserting", key = val.key.data, val=val.val.data
  self.entries[val.key] = (val.val, val.time)
