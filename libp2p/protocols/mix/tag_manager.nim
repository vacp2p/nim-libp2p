# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sets, locks

type
  ## Tag is H(α || s) as per spec Section 8.6.1 Step 2
  Tag* = array[32, byte]

  TagManager* = ref object
    lock: Lock
    seenTags: HashSet[Tag]

proc new*(T: typedesc[TagManager]): T =
  let tm = T()
  tm.seenTags = initHashSet[Tag]()
  initLock(tm.lock)
  return tm

proc addTag*(tm: TagManager, tag: Tag) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags.incl(tag)

proc isTagSeen*(tm: TagManager, tag: Tag): bool {.gcsafe.} =
  withLock tm.lock:
    return tm.seenTags.contains(tag)

proc removeTag*(tm: TagManager, tag: Tag) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags.excl(tag)

proc clearTags*(tm: TagManager) {.gcsafe.} =
  withLock tm.lock:
    tm.seenTags.clear()
