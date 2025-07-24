import std/[tables, hashes]

type EntryKey = object
  data: seq[byte]

type EntryVal = object
  data: seq[byte]

type TimeStamp = object
  # Currently a string, because for some reason, that's what is chosen at the protobuf level
  # TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
  ts: string

type EntryCandidate = object
  key*: EntryKey
  val*: EntryVal
  time*: TimeStamp

type ValidatedEntry = object
  key: EntryKey
  val: EntryVal
  time: TimeStamp

type RecordVal = object
  value: EntryVal
  time: TimeStamp

type LocalTable* = object
  entries: Table[EntryKey, (EntryVal, TimeStamp)]

proc init*(self: typedesc[LocalTable]): LocalTable {.raises: [].} =
  LocalTable(entries: Table.init())

proc insert*(self: var LocalTable, val: sink ValidatedEntry) =
  self.entries[val.key] = (val.val, val.time)

type BaseValidator = object

proc validate*(
    self: typedesc[BaseValidator], candidate: sink EntryCandidate
): ValidatedEntry {.raises: [].} =
  doAssert(false, "[BaseValidator.advertise] abstract method not implemented!")
