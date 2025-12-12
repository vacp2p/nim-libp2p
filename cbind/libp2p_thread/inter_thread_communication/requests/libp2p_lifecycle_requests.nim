# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Thread Request Example Implementation
#
# This file defines the `LifecycleRequest` type and its lifecycle, including memory
# management and request processing. This structure is used for communicating with the
# main thread, which is the one that runs LibP2P

import std/[json]
import chronos, results, chronicles

import ../../../[types]
import ../../../../libp2p
import ../../../../libp2p/nameresolving/[dnsresolver, nameresolver]
import ../../../../libp2p/protocols/pubsub/gossipsub
import ../../../../libp2p/protocols/kademlia


type LifecycleMsgType* = enum
  CREATE_LIBP2P
  START_NODE
  STOP_NODE

type LifecycleRequest* = object
  operation: LifecycleMsgType
  appCallbacks: AppCallbacks

proc createLibp2p(appCallbacks: AppCallbacks): LibP2P =
  # TODO: switch options
  let dnsResolver =
    Opt.some(cast[NameResolver](DnsResolver.new(@[initTAddress("1.1.1.1:53")])))
  let switch = newStandardSwitch(nameResolver = dnsResolver)

  # TODO: this should be optional depending on parameters
  let gossipSub = GossipSub.init(switch = switch, triggerSelf = true)
  switch.mount(gossipSub)

  let kad = KadDHT.new(switch)
  switch.mount(kad)

  LibP2P(switch: switch, gossipSub: gossipSub, kad: kad)

proc createShared*(
    T: type LifecycleRequest, op: LifecycleMsgType, appCallbacks: AppCallbacks = nil
): ptr type T =
  # TODO: Modify for your request's specific field initialization
  # TODO: Allocate parameters of GC'd types to the shared memory
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  return ret

proc destroyShared(self: ptr LifecycleRequest) =
  # TODO: Free any newly added fields here if you change the object structure
  # TODO: Deallocate parameters of GC'd types from the shared memory
  deallocShared(self)

proc process*(
    self: ptr LifecycleRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_LIBP2P:
    try:
      libp2p[] = createLibp2p(self.appCallbacks)
    except TransportAddressError as exc:
      return err("could not create libp2p node: " & $exc.msg)
    except LPError as exc:
      return err("could not create libp2p node: " & $exc.msg)
  of START_NODE:
    try:
      await libp2p.switch.start()
    except LPError:
      return err(getCurrentExceptionMsg())
  of STOP_NODE:
    await libp2p.switch.stop()

  return ok("")
