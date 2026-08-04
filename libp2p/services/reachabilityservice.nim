# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import chronos, results
import ../switch
import ../multiaddress
import ../protocols/connectivity/autonat/types
import ../utils/future

export types.NetworkReachability

type
  ReachabilityHandler* = proc(
    reachability: NetworkReachability,
    confidence: Opt[float],
    dialBackAddr: Opt[MultiAddress],
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).}
    ## A subscriber of reachability changes. A subscriber that needs no
    ## `confidence` or `dialBackAddr` leaves those parameters unused. AutoNAT v1
    ## reports `dialBackAddr` as none, because it observes no dial-back address.

  ReachabilityService* = ref object of Service
    ## A Service that observes network reachability and notifies subscribers.
    handlers: seq[ReachabilityHandler]

method addReachabilityHandler*(
    self: ReachabilityService, handler: ReachabilityHandler
): bool {.base, gcsafe, discardable.} =
  ## Appends `handler`. False means no subscription: a nil handler is dropped.
  if handler.isNil():
    return false

  self.handlers.add(handler)
  true

method removeReachabilityHandler*(
    self: ReachabilityService, handler: ReachabilityHandler
): bool {.base, gcsafe.} =
  ## Removes `handler`. False means it was not subscribed.
  let before = self.handlers.len
  self.handlers.keepItIf(it != handler)
  self.handlers.len < before

method networkReachability*(
    self: ReachabilityService
): NetworkReachability {.base, gcsafe.} =
  raiseAssert(
    "[ReachabilityService.networkReachability] abstract method not implemented!"
  )

proc callHandlers*(
    self: ReachabilityService,
    confidence: Opt[float],
    dialBackAddr = Opt.none(MultiAddress),
) {.async: (raises: [CancelledError]).} =
  # Handlers start in subscription order, then run concurrently, so a subscriber
  # that blocks does not delay the subscribers behind it.
  await allOrCancel(
    self.handlers.mapIt(it(self.networkReachability, confidence, dialBackAddr))
  )
