{.push raises: [Defect].}

import
  std/[macros, options, tables],
  chronos, chronicles, bearssl,
  switch, peerid, peerinfo,
  sequtils

export switch, peerid, peerinfo

type
  SwitchBuilder* = ref object
    switch: Switch
    locks: Table[string, string]
    finishedMounting: seq[proc() {.gcsafe.}]
    mounting: string

proc new*(T: type[SwitchBuilder], switchType: type[Switch] = Switch): T =
  T(
    switch: switchType(peerStore: PeerStore.new())
  )

template borrowVar(toBorrow: untyped) =
  const field = $typeof(Switch.toBorrow) # Shows "seq[Transport]"
  #const field = astToStr(toBorrow)      # Shows "transports"


  # Goal is to avoid 2 things:
  # - Someone using something which is not initialized
  # - Someone writing to a variable which has already been used
  #   by somebody else.
  #
  # For refs, it's easy:
  # When someone access it, we check if it's nil. If it's nil, we raise
  # If someone access it and it's not nil, we'll store who accessed to it
  # in the `lock` table. If someone tries to write to it afterward, we'll throw
  #
  #
  # For seq & table it's basically the same, the only issue is
  # that we don't know when people write to it, because they just do
  # `sequence.add(value)`, which just calls toBorrow, and not toBorrow=
  #
  # Instead, when someone access it, we store the current length
  # and when he's done mounting it, we have 2 cases:
  #
  # oldLen == newLen: user copied it, verify that it was initialised + lock
  # oldLen < newLen: user added something to it, verify that it isn't locked

  proc toBorrow*(switchBuilder: SwitchBuilder): var typeof(Switch.toBorrow) =
    when Switch.toBorrow is ref:
      if isNil switchBuilder.switch.toBorrow:
        raise newException(Defect,
          "With(" & switchBuilder.mounting & "): " & field & " should be setup first")

    when Switch.toBorrow is seq or Switch.toBorrow is Table:
      let currentLen = switchBuilder.switch.toBorrow.len

      switchBuilder.finishedMounting &= proc() =
        if switchBuilder.switch.toBorrow.len != currentLen: # Wrote to it
          if field in switchBuilder.locks:
            raise newException(Defect,
              "With(" & switchBuilder.mounting & "): can't be done after With(" & switchBuilder.locks.getOrDefault(field) & ")")
        else: # Read it
          if switchBuilder.switch.toBorrow.len == 0:
            raise newException(Defect,
              "With(" & switchBuilder.mounting & "): " & field & " should be setup first")

          if field notin switchBuilder.locks:
            switchBuilder.locks[field] = switchBuilder.mounting

      return switchBuilder.switch.toBorrow

    if field notin switchBuilder.locks:
      switchBuilder.locks[field] = switchBuilder.mounting

    switchBuilder.switch.toBorrow

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

proc build*(switchBuilder: SwitchBuilder): Switch =
  # to throw if Dialer is not set
  discard switchBuilder.dialer
  switchBuilder.switch

{.pop.}
# mount can raise

# borrow
proc mount*(s: SwitchBuilder, proto: LPProtocol, matcher: Matcher = nil)
  {.gcsafe, raises: [Defect, LPError].} =

  # to throw if ms is not set
  discard s.ms
  s.switch.mount(proto, matcher)

proc with*[T](switchBuilder: SwitchBuilder, val: T): T {.discardable.} =
  switchBuilder.mounting = $typeof(val)
  switchBuilder.finishedMounting.setLen(0)
  switchBuilder.setup(val)
  for handler in switchBuilder.finishedMounting:
    handler()
  switchBuilder.mounting = "Unknown"
  val

template with*(switchBuilder: SwitchBuilder, args: varargs[untyped]) =
  #switchBuilder.with(unpackVarargs(new, args))
  switchBuilder.with(new(args))
