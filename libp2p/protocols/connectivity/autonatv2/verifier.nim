# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## An `AddressManager` verifier backed by AutoNATv2. It asks a connected peer to
## dial each candidate back.

{.push raises: [].}

import std/sequtils
import results
import chronos, chronicles
import
  ../../../address_manager,
  ../../../crypto/crypto,
  ../../../errors,
  ../../../multiaddress,
  ../../../peerid,
  ../../../switch,
  ./client,
  ./types,
  ./utils

logScope:
  topics = "libp2p autonatv2 verifier"

const AskTimeout = 2 * DefaultDialTimeout ## Twice the time a server has to dial back.

type AutonatV2Verifier* = ref object of Verifier
  switch: Switch
  client: AutonatV2Client
  rng: Rng

proc new*(
    T: typedesc[AutonatV2Verifier], switch: Switch, client: AutonatV2Client, rng: Rng
): T =
  ## The switch must mount `client`, which receives the dial back.
  client.setup(switch)
  T(switch: switch, client: client, rng: rng)

proc selectPeer(self: AutonatV2Verifier): Opt[PeerId] =
  ## A peer which dialed us proves nothing. It has a path to us already.
  self.rng.pickOne(
    self.switch.connectedPeers(Direction.Out).filterIt(
      not self.switch.hasIncomingConn(it)
    )
  )

proc askPeer(
    self: AutonatV2Verifier, peerId: PeerId, address: MultiAddress
): Future[Opt[AddrState]] {.async: (raises: [CancelledError]).} =
  let reachability =
    try:
      (await self.client.sendDialRequest(peerId, @[address]).wait(AskTimeout)).reachability
    except CancelledError as e:
      raise e
    except AsyncTimeoutError:
      debug "DialRequest timed out", peerId, address
      return Opt.none(AddrState)
    except LPError as e:
      debug "DialRequest failed", peerId, address, description = e.msg
      return Opt.none(AddrState)

  case reachability
  of Reachable:
    Opt.some(AddrState.Confirmed)
  of NotReachable:
    Opt.some(AddrState.Unreachable)
  of Unknown:
    Opt.none(AddrState)

method verify*(
    self: AutonatV2Verifier, addresses: seq[MultiAddress]
): Future[seq[AddrVerdict]] {.async: (raises: [CancelledError]).} =
  ## One request per address, each to a peer of its own. A server dials back one
  ## address per request, and it picks which one.
  var verdicts: seq[AddrVerdict]
  for address in addresses:
    if not self.switch.hasEnoughIncomingSlots():
      debug "No incoming slots left, stopping verification",
        verified = verdicts.len, candidates = addresses.len
      break

    let peerId = self.selectPeer().valueOr:
      debug "No peer to ask"
      break

    (await self.askPeer(peerId, address)).withValue(state):
      verdicts.add(AddrVerdict(address: address, state: state))
  verdicts
