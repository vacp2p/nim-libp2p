import chronicles, chronos, metrics
import ../../builders
import ../../stream/connection
import ./mix_metrics

type ExitLayer* = object
  switch: Switch

proc init*(T: typedesc[ExitLayer], switch: Switch): T =
  ExitLayer(switch: switch)

proc onMessage*(
    self: ExitLayer,
    codec: string,
    message: seq[byte],
    destAddr: MultiAddress,
    destPeerId: PeerId,
) {.async: (raises: [CancelledError]).} =
  var destConn: Connection
  try:
    destConn = await self.switch.dial(destPeerId, @[destAddr], codec)
    await destConn.write(message)
  except CatchableError as e:
    error "Failed to dial next hop: ", err = e.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "DIAL_FAILED"])
    return
  finally:
    if not destConn.isNil:
      await destConn.close()
