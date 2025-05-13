import chronos
import chronicles
import stew/byteutils
import ../libp2p
import ../libp2p/[builders, transports/wstransport]

const TestCodec = "/test/echo/1.0.0"

type TestProto = ref object of LPProtocol

proc new(T: typedesc[TestProto]): T =
  # every incoming connections will in be handled in this closure
  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    # Read up to 1024 bytes from this connection, and transform them into
    # a string
    try:
      info "Got from remote - ", msg = string.fromBytes(await conn.readLp(1024))
    except CancelledError as e:
      raise e
    except CatchableError as e:
      error "exception in handler", err = e.msg
    finally:
      await conn.close()

  return T.new(codecs = @[TestCodec], handler = handle)

proc main() {.async.} =
  let rng = newRng()
  let testProto = TestProto.new()
  var switchBuilder = SwitchBuilder.new()
  discard switchBuilder.withTransport(
    proc(upgr: Upgrade, privateKey: PrivateKey): Transport =
      WsTransport.new(upgr)
  )
  discard
    switchBuilder.withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/60123/ws").tryGet())
  discard switchBuilder.withNoise()
  discard switchBuilder.withYamux()
  discard switchBuilder.withRng(rng)

  let switch1 = switchBuilder.build()

  switch1.mount(testProto)

  await switch1.start()

  await sleepAsync(1.hours)

  await allFutures(switch1.stop())

waitFor(main())
