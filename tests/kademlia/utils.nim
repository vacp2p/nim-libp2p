# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
{.used.}

import std/tables, results, chronos
import ../../libp2p/[protocols/kademlia, switch, builders]

type PermissiveValidator* = ref object of EntryValidator
method isValid*(self: PermissiveValidator, key: Key, record: EntryRecord): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method isValid(self: RestrictiveValidator, key: Key, record: EntryRecord): bool =
  false

type CandSelector* = ref object of EntrySelector
method select*(
    self: CandSelector, key: Key, values: seq[EntryRecord]
): Result[int, string] =
  return ok(0)

type OthersSelector* = ref object of EntrySelector
method select*(
    self: OthersSelector, key: Key, values: seq[EntryRecord]
): Result[int, string] =
  if values.len == 0:
    return err("no values were given")
  if values.len == 1:
    return ok(0)
  ok(1)

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

proc countBucketEntries*(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

proc containsData*(kad: KadDHT, key: Key, value: seq[byte]): bool {.raises: [].} =
  try:
    kad.dataTable[key].value == value
  except KeyError:
    false

proc containsNoData*(kad: KadDHT, key: Key): bool {.raises: [].} =
  not containsData(kad, key, @[])

template setupKadSwitch*(validator: untyped, selector: untyped): untyped =
  let switch = createSwitch()
  let kad = KadDHT.new(
    switch, config = KadDHTConfig.new(validator, selector, timeout = chronos.seconds(1))
  )
  switch.mount(kad)
  await switch.start()
  (switch, kad)
