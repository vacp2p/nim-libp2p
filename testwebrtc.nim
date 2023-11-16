import chronos, libp2p, libp2p/transports/webrtctransport

proc main {.async.} =
  let switch =
    SwitchBuilder.new()
    .withAddress(MultiAddress.init("/ip4/127.0.0.1/udp/4242/webrtc-direct/certhash/uEiDDq4_xNyDorZBH3TlGazyJdOWSwvo4PUo5YHFMrvDE8g").tryGet()) #TODO the certhash shouldn't be necessary
    .withRng(crypto.newRng())
    .withMplex()
    .withTransport(proc (upgr: Upgrade): Transport = WebRtcTransport.new(upgr))
    .withNoise()
    .build()

  await switch.start()
  await sleepAsync(1.hours)

waitFor main()
