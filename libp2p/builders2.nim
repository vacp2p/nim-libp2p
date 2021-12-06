{.push raises: [Defect].}

import
  macros,
  options, tables, chronos, chronicles, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure, secure/noise],
  connmanager, upgrademngrs/muxedupgrade,
  nameresolving/nameresolver,
  errors,
  sequtils

export
  switch, peerid, peerinfo, connection, multiaddress, crypto, errors

type
  SwitchBuilder* = ref object
    switch*: Switch
    locks: Table[string, string]
    mounting: string

proc new*(T: type[SwitchBuilder], peerInfo: PeerInfo): T =
  T(
    switch: Switch.new(peerInfo)
  )

proc new*(T: type[SwitchBuilder],
  addrs: seq[MultiAddress],
  rng = newRng()): T =

  try:
    let
      secKey = PrivateKey.random(rng[])
      peerInfo = PeerInfo.new(secKey.tryGet(), addrs)
    result = T.new(peerInfo)
  except: discard

template liftVar(name: untyped) =
  proc name*(switchBuilder: SwitchBuilder): auto =
    #const field = $typeof(switchBuilder.switch.name)
    const field = astToStr(name)

    when switchBuilder.switch.name is ref:
      if isNil switchBuilder.switch.name:
        echo "With(" & switchBuilder.mounting & "): " & field & " should be setup first"
    when switchBuilder.switch.name is seq:
      if switchBuilder.switch.name.len == 0:
        echo "With(" & switchBuilder.mounting & "): " & field & " should be setup first"
    when switchBuilder.switch.name is Table:
      if toSeq(switchBuilder.switch.name.keys).len == 0:
        echo "With(" & switchBuilder.mounting & "): " & field & " should be setup first"

    if field notin switchBuilder.locks:
      switchBuilder.locks[field] = switchBuilder.mounting

    switchBuilder.switch.name

  proc `name=`*(switchBuilder: SwitchBuilder, value: auto): auto =
    const field = astToStr(name)

    if field in switchBuilder.locks:
      echo "With(" & switchBuilder.mounting & "): can't be done after With(" & switchBuilder.locks.getOrDefault(field) & ")"
    switchBuilder.switch.name = value

liftVar(identify)
liftVar(peerInfo)
liftVar(muxers)
liftVar(secureManagers)
liftVar(connManager)
liftVar(ms)
liftVar(dialer)
liftVar(transports)

proc with*(switchBuilder: SwitchBuilder, T: typedesc): T {.discardable.} =
  switchBuilder.mounting = $T
  let val = T.new()
  switchBuilder.switchWith(val)
  val

proc with*[T](switchBuilder: SwitchBuilder, val: T): T {.discardable.} =
  switchBuilder.mounting = $typeof(val)
  switchBuilder.switchWith(val)
  val

#proc with*(switchBuilder: SwitchBuilder, T: typedesc): T {.discardable.} =
#  switchBuilder.mounting = $T
#  let val = T.new()
#  switchBuilder.switchWith(val)
#  val

proc build*(switchBuilder: SwitchBuilder): Switch = switchBuilder.switch
