{.used.}

import options, chronos
import stew/byteutils
import ../libp2p/[protocols/discovery/rendezvous,
                  switch,
                  builders,]
import ./helpers

suite "RendezVous":
  asyncTest "Simple local test":
    let
      s = newStandardSwitch()
      rdv = RendezVous.new(s)
    s.mount(rdv)
    await s.start()
    await rdv.advertise("foo")
    let res1 = await rdv.request("foo")
    check:
      res1.len == 1
      res1[0] == s.peerInfo.signedPeerRecord.data
    let res2 = await rdv.request("bar")
    check res2.len == 0
