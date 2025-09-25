import chronicles, chronos, metrics, sequtils
import ../../builders
import ../../stream/connection
import ./[mix_metrics, reply_connection, serialization]

type OnReplyDialer* =
  proc(surb: SURB, message: seq[byte]) {.async: (raises: [CancelledError]).}

## Callback type for reading responses from a destination connection
type destReadBehaviorCb* = proc(conn: Connection): Future[seq[byte]] {.
  async: (raises: [CancelledError, LPStreamError])
.}

type ExitLayer* = object
  switch: Switch
  onReplyDialer: OnReplyDialer
  destReadBehavior: TableRef[string, destReadBehaviorCb]

proc init*(
    T: typedesc[ExitLayer],
    switch: Switch,
    onReplyDialer: OnReplyDialer,
    destReadBehavior: TableRef[string, destReadBehaviorCb],
): T =
  ExitLayer(
    switch: switch, onReplyDialer: onReplyDialer, destReadBehavior: destReadBehavior
  )

proc replyDialerCbFactory(self: ExitLayer): MixReplyDialer =
  return proc(
      surbs: seq[SURB], msg: seq[byte]
  ): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
    let respFuts = surbs.mapIt(self.onReplyDialer(it, msg))
    await allFutures(respFuts)

proc reply(
    self: ExitLayer, surbs: seq[SURB], response: seq[byte]
) {.async: (raises: [CancelledError]).} =
  if surbs.len == 0:
    return

  let replyConn = MixReplyConnection.new(surbs, self.replyDialerCbFactory())
  defer:
    await replyConn.close()
  try:
    await replyConn.write(response)
  except LPStreamError as exc:
    error "could not reply", description = exc.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "REPLY_FAILED"])

proc onMessage*(
    self: ExitLayer,
    codec: string,
    message: seq[byte],
    destAddr: MultiAddress,
    destPeerId: PeerId,
    surbs: seq[SURB],
) {.async: (raises: [CancelledError]).} =
  # If dialing destination fails, no response is returned to
  # the sender, so, flow can just end here. Only log errors
  # for now
  # https://github.com/vacp2p/mix/issues/86

  var response: seq[byte]
  try:
    let destConn = await self.switch.dial(destPeerId, @[destAddr], codec)
    defer:
      await destConn.close()
    await destConn.write(message)

    if surbs.len != 0:
      if not self.destReadBehavior.hasKey(codec):
        error "No destReadBehavior for codec", codec
        return

      var behaviorCb: destReadBehaviorCb
      try:
        behaviorCb = self.destReadBehavior[codec]
      except KeyError:
        doAssert false, "checked with HasKey"

      response = await behaviorCb(destConn)
  except LPStreamError as exc:
    error "Stream error while writing to next hop: ", err = exc.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "LPSTREAM_ERR"])
  except DialFailedError as exc:
    error "Failed to dial next hop: ", err = exc.msg
    mix_messages_error.inc(labelValues = ["ExitLayer", "DIAL_FAILED"])
  except CancelledError as exc:
    raise exc

  await self.reply(surbs, response)
