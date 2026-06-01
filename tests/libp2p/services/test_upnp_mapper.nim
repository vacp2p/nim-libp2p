# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos, results
import ../../../libp2p/services/nat/[portmapper, upnp_mapper]
import ../../tools/unittest

suite "UpnpMapper":
  teardown:
    checkTrackers()

  asyncTest "create + close is clean (no dispatch in between)":
    let m = newUpnpMapper()
    await m.close()

  asyncTest "double close is a no-op":
    let m = newUpnpMapper()
    await m.close()
    await m.close()

  asyncTest "discover after close returns 'closed' error":
    let m = newUpnpMapper()
    await m.close()

    let r = await m.discover(50.milliseconds)
    check r.isErr
    check r.error == "UpnpMapper closed"

  asyncTest "map after close returns 'closed' error":
    let m = newUpnpMapper()
    await m.close()

    let r = await m.map(Port(9000), Port(9000), mpTcp, 3600'u32)
    check r.isErr
    check r.error == "UpnpMapper closed"

  asyncTest "unmap after close returns 'closed' error":
    let m = newUpnpMapper()
    await m.close()

    let r = await m.unmap(Port(9000), mpTcp)
    check r.isErr
    check r.error == "UpnpMapper closed"

  asyncTest "cancelling in-flight discover is observable and close still cleans up":
    # Cancel a dispatch that is awaiting the worker, then close. The worker
    # continues until miniupnpc returns; the dispatch's CancelledError branch
    # drains respSignal (via noCancel) so the next dispatch doesn't read this
    # cancelled request's response, and close() waits (via noCancel) for the
    # in-flight dispatch to release the lock before tearing the worker down.
    let m = newUpnpMapper()
    let fut = m.discover(200.milliseconds)
    await sleepAsync(10.milliseconds)
    fut.cancelSoon()

    try:
      discard await fut
    except CancelledError:
      discard

    await m.close()

  asyncTest "concurrent dispatches are serialized by the lock":
    # Without the lock, the second dispatch would overwrite ctx.request before
    # the worker finishes the first. Firing two discovers back-to-back must
    # produce results in submission order.
    let m = newUpnpMapper()
    defer:
      await m.close()

    var order: seq[int]
    proc tag(i: int): Future[void] {.async: (raises: [CancelledError]).} =
      discard await m.discover(50.milliseconds)
      order.add(i)

    let f1 = tag(1)
    let f2 = tag(2)
    await allFutures(f1, f2)
    check order == @[1, 2]
