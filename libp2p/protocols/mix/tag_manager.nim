# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Tag Manager for Mix Protocol Replay Protection
##
## Uses TimedCache with refreshOnPut=false to ensure first-seen time is preserved
## (important for replay protection where extending expiry on re-add would be a vulnerability).

import chronicles, chronos
import ../pubsub/timedcache
import ../../utils/heartbeat

const
  DefaultTagTTL* = chronos.hours(1)
  DefaultPurgeInterval* = chronos.minutes(5)

type
  ## Tag is H(α || s) as per spec Section 8.6.1 Step 2
  Tag* = array[32, byte]

  TagManager* = ref object
    cache: TimedCache[Tag]
    tagTTL: Duration
    purgeInterval: Duration
    purgeLoop: Future[void]

proc len*(tm: TagManager): int {.inline.} =
  ## Returns the number of tags currently stored.
  tm.cache.len

proc purgeExpiredTags*(tm: TagManager, now: Moment = Moment.now()): int =
  ## Remove tags that have expired.
  ## Returns the number of tags purged.
  let before = tm.cache.len
  tm.cache.expire(now)
  before - tm.cache.len

proc purgeLoopProc(tm: TagManager) {.async: (raises: [CancelledError]).} =
  ## Periodically purges expired tags using the heartbeat pattern.
  heartbeat "Tag purge", tm.purgeInterval, sleepFirst = true:
    let purged = tm.purgeExpiredTags()
    if purged > 0:
      trace "Purged expired replay tags", count = purged, remaining = tm.len

proc start*(tm: TagManager) =
  ## Start the background purge loop.
  if tm.purgeLoop.isNil or tm.purgeLoop.finished:
    tm.purgeLoop = tm.purgeLoopProc()

proc stop*(tm: TagManager) {.async: (raises: []).} =
  ## Stop the background purge loop and wait for it to finish.
  if not tm.purgeLoop.isNil and not tm.purgeLoop.finished:
    await tm.purgeLoop.cancelAndWait()

proc stopSoon*(tm: TagManager) =
  ## Stop the background purge loop without waiting.
  ## Use this in non-async contexts or when immediate return is needed.
  if not tm.purgeLoop.isNil and not tm.purgeLoop.finished:
    tm.purgeLoop.cancelSoon()

proc new*(
    T: typedesc[TagManager],
    tagTTL: Duration = DefaultTagTTL,
    purgeInterval: Duration = DefaultPurgeInterval,
    autoStart: bool = true,
): T =
  let tm = T(
    cache: TimedCache[Tag].init(timeout = tagTTL, refreshOnPut = false),
    tagTTL: tagTTL,
    purgeInterval: purgeInterval,
  )
  if autoStart:
    tm.start()
  tm

proc addTag*(tm: TagManager, tag: Tag, now: Moment = Moment.now()) =
  ## Add a tag to the manager. If already present, this is a no-op
  ## (does not refresh expiry - first seen time is what matters for replay protection).
  discard tm.cache.put(tag, now)

proc isTagSeen*(tm: TagManager, tag: Tag): bool {.inline.} =
  ## Check if a tag has been seen (and hasn't expired).
  tag in tm.cache

proc removeTag*(tm: TagManager, tag: Tag) =
  ## Remove a specific tag.
  discard tm.cache.del(tag)

proc clearTags*(tm: TagManager) =
  ## Remove all tags.
  tm.cache = TimedCache[Tag].init(timeout = tm.tagTTL, refreshOnPut = false)
