import tables, locks
import ./curve25519

type TagManager* = ref object
  lock: Lock
  seenTags: Table[FieldElement, bool]

proc new*(T: typedesc[TagManager]): T =
  let tm = T()
  tm.seenTags = initTable[FieldElement, bool]()
  initLock(tm.lock)
  return tm

proc addTag*(tm: TagManager, tag: FieldElement) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags[tag] = true

proc isTagSeen*(tm: TagManager, tag: FieldElement): bool {.gcsafe.} =
  withLock tm.lock:
    return tm.seenTags.contains(tag)

proc removeTag*(tm: TagManager, tag: FieldElement) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags.del(tag)

proc clearTags*(tm: TagManager) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags.clear()
