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
  # If dialing destination fails, no response is returned to
  # the sender, so, flow can just end here. Only log errors
  # for now
  # https://github.com/vacp2p/mix/issues/86

  try:
    let destConn = await self.switch.dial(destPeerId, @[destAddr], codec)
    defer:
      await destConn.close()
    await destConn.write(message)
  except LPStreamError as exc:
    error "Stream error while writing to next hop: ", err = exc.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "LPSTREAM_ERR"])
  except DialFailedError as exc:
    error "Failed to dial next hop: ", err = exc.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "DIAL_FAILED"])
  except CancelledError as exc:
    raise exc
