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
    switch: Switch
    locks: Table[string, string]
    mounting: string

proc new*(T: type[SwitchBuilder], switchType: type[Switch] = Switch): T =
  T(
    switch: switchType.new()
  )

#proc new*(T: type[SwitchBuilder],
#  addrs: seq[MultiAddress],
#  rng = newRng()): T =
#
#  try:
#    let
#      secKey = PrivateKey.random(rng[])
#      peerInfo = PeerInfo.new(secKey.tryGet(), addrs)
#    result = T.new(peerInfo)
#  except: discard

template borrowVar(toBorrow: untyped) =
  const field = $typeof(Switch.toBorrow) # Shows "seq[Transport]"
  #const field = astToStr(toBorrow)      # Shows "transports"

  proc toBorrow*(switchBuilder: SwitchBuilder): auto =
    let isNotSetup =
      when Switch.toBorrow is ref:
        isNil switchBuilder.switch.toBorrow
      elif Switch.toBorrow is seq:
        switchBuilder.switch.toBorrow.len == 0
      elif Switch.toBorrow is Table:
        toSeq(switchBuilder.switch.toBorrow.keys).len == 0

    if isNotSetup:
      raise newException(Defect,
        "With(" & switchBuilder.mounting & "): " & field & " should be setup first")

    if field notin switchBuilder.locks:
      switchBuilder.locks[field] = switchBuilder.mounting

    switchBuilder.switch.toBorrow

  proc `toBorrow Add`*(switchBuilder: SwitchBuilder, value: auto) =
    if field in switchBuilder.locks:
      raise newException(Defect,
        "With(" & switchBuilder.mounting & "): can't be done after With(" & switchBuilder.locks.getOrDefault(field) & ")")
    # I don't like this
    switchBuilder.switch.toBorrow &= value

  proc `toBorrow Add`*(switchBuilder: SwitchBuilder, key, value: auto) =
    if field in switchBuilder.locks:
      raise newException(Defect,
        "With(" & switchBuilder.mounting & "): can't be done after With(" & switchBuilder.locks.getOrDefault(field) & ")")
    # I don't like this
    switchBuilder.switch.toBorrow[key] = value

  proc `toBorrow=`*(switchBuilder: SwitchBuilder, value: auto): auto =
    if field in switchBuilder.locks:
      raise newException(Defect,
        "With(" & switchBuilder.mounting & "): can't be done after With(" & switchBuilder.locks.getOrDefault(field) & ")")
    switchBuilder.switch.toBorrow = value

borrowVar(identify)
borrowVar(peerStore)
borrowVar(peerInfo)
borrowVar(muxers)
borrowVar(secureManagers)
borrowVar(connManager)
borrowVar(ms)
borrowVar(dialer)
borrowVar(transports)

# borrow
proc mount*(s: SwitchBuilder, proto: LPProtocol, matcher: Matcher = nil)
  {.gcsafe, raises: [Defect, LPError].} =

  # to throw if ms is not set
  discard s.ms
  s.switch.mount(proto, matcher)

proc with*[T](switchBuilder: SwitchBuilder, val: T): T {.discardable.} =
  switchBuilder.mounting = $typeof(val)
  switchBuilder.switchWith(val)
  switchBuilder.mounting = "Unknown"
  val

template with*(switchBuilder: SwitchBuilder, args: varargs[untyped]) =
  #switchBuilder.with(unpackVarargs(new, args))
  switchBuilder.with(new(args))

proc build*(switchBuilder: SwitchBuilder): Switch =
  # to throw if Dialer is not set
  discard switchBuilder.dialer
  switchBuilder.switch
