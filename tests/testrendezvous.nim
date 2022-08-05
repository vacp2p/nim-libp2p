{.used.}

import options, chronos
import stew/byteutils
import ../libp2p/[protocols/rendezvous,
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
    let res1 = rdv.requestLocally("foo")
    check:
      res1.len == 1
      res1[0] == s.peerInfo.signedPeerRecord.data
    let res2 = rdv.requestLocally("bar")
    check res2.len == 0
