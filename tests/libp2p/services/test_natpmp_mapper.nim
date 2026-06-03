# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos, results
import ../../../libp2p/services/nat/[portmapper, natpmp_mapper]
import ../../tools/unittest

suite "NatPmpMapper":
  teardown:
    checkTrackers()

  asyncTest "create + close is clean (no dispatch in between)":
    let m = NatPmpMapper.new()
    await m.close()

  asyncTest "double close is a no-op":
    let m = NatPmpMapper.new()
    await m.close()
    await m.close()

  asyncTest "discover after close returns 'closed' error":
    let m = NatPmpMapper.new()
    await m.close()

    let r = await m.discover(50.milliseconds)
    check r.isErr()
    check r.error() == "NatPmpMapper closed"

  asyncTest "map after close returns 'closed' error":
    let m = NatPmpMapper.new()
    await m.close()

    let r = await m.map(Port(9000), Port(9000), mpTcp, 3600'u32)
    check r.isErr()
    check r.error() == "NatPmpMapper closed"

  asyncTest "unmap after close returns 'closed' error":
    # unmap short-circuits with "no known mapping" before reaching dispatch
    # unless a prior map() populated self.mappings. Without a real gateway we
    # can't populate it, so this test exercises the no-mapping path — which is
    # the closest equivalent to upnp's "unmap after close" check.
    let m = NatPmpMapper.new()
    await m.close()

    let r = await m.unmap(Port(9000), mpTcp)
    check r.isErr()
    check r.error() == "natpmp unmap: no known mapping for external port 9000"

  asyncTest "map with lease=0 is rejected before dispatch":
    # libnatpmp treats lifetime == 0 as a delete request (RFC 6886 §3.4), so
    # the mapper rejects it outright instead of forwarding it to the worker.
    let m = NatPmpMapper.new()
    defer:
      await m.close()

    let r = await m.map(Port(9000), Port(9000), mpTcp, 0'u32)
    check r.isErr()
    check r.error() ==
      "natpmp map: lease must be > 0 (lease=0 deletes the mapping per RFC 6886)"

  asyncTest "unmap without a prior map returns 'no known mapping' error":
    # NAT-PMP identifies a mapping by (internal port, protocol), but unmap's
    # public signature only carries the external port. The mapper records the
    # internal port on successful map(); without that record there is nothing
    # to send to the gateway.
    let m = NatPmpMapper.new()
    defer:
      await m.close()

    let r = await m.unmap(Port(9000), mpTcp)
    check r.isErr()
    check r.error() == "natpmp unmap: no known mapping for external port 9000"

  asyncTest "cancelling in-flight discover is observable and close still cleans up":
    # Cancel a dispatch that is awaiting the worker, then close. The worker
    # continues until libnatpmp returns; close() cancels the in-flight wait
    # so dispatch can release the lock, then acquires the lock uncancellably
    # before tearing the worker down.
    let m = NatPmpMapper.new()
    let fut = m.discover(200.milliseconds)
    # sleepAsync gives the dispatch a chance to park on respSignal before we
    # cancel — otherwise cancellation may land before there is anything in
    # flight to observe.
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
    # produce results in submission order, even when each individual dispatch
    # times out (no NAT-PMP gateway in CI).
    let m = NatPmpMapper.new()
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
