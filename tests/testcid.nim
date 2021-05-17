import unittest2
import ../libp2p/[cid, multihash, multicodec]

when defined(nimHasUsed): {.used.}

suite "Content identifier CID test suite":

  test "CIDv0 test vector":
    var cid0Text = "QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n"
    var cid0 = Cid.init(cid0Text).tryGet()
    check:
      $cid0 == cid0Text
      cid0.version() == CIDv0
      cid0.contentType().tryGet() == multiCodec("dag-pb")
      cid0.mhash().tryGet().mcodec == multiCodec("sha2-256")
      Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zIII").isErr()

  test "CIDv1 test vector":
    var cid1Text = "zb2rhhFAEMepUBbGyP1k8tGfz7BSciKXP6GHuUeUsJBaK6cqG"
    var chex = "015512209D8453505BDC6F269678E16B3E56" &
               "C2A2948A41F2C792617CC9611ED363C95B63"
    var cid1 = Cid.init(cid1Text).tryGet()
    check:
      $cid1 == cid1Text
      cid1.version() == CIDv1
      cid1.contentType().tryGet() == multiCodec("raw")
      cid1.mhash().tryGet().mcodec == multiCodec("sha2-256")
      hex(cid1) == chex

  test "Comparison test":
    var msg = "Hello World!"
    var mmsg = "Hello World!Hello World!"
    var bmsg = cast[seq[byte]](msg)
    var bmmsg = cast[seq[byte]](mmsg)
    var cid0 = Cid.init(CIDv0, multiCodec("dag-pb"),
                        MultiHash.digest("sha2-256", bmsg).get()).tryGet()
    var cid1 = Cid.init(CIDv1, multiCodec("dag-pb"),
                        MultiHash.digest("sha2-256", bmsg).get()).tryGet()
    var cid2 = cid1
    var cid3 = cid0
    var cid4 = Cid.init(CIDv1, multiCodec("dag-cbor"),
                        MultiHash.digest("sha2-256", bmsg).get()).tryGet()
    var cid5 = Cid.init(CIDv1, multiCodec("dag-pb"),
                        MultiHash.digest("sha2-256", bmmsg).get()).tryGet()
    var cid6 = Cid.init(CIDv1, multiCodec("dag-pb"),
                        MultiHash.digest("keccak-256", bmsg).get()).tryGet()
    check:
      cid0 == cid1
      cid1 == cid2
      cid2 == cid3
      cid3 == cid0
      cid0 != cid4
      cid1 != cid5
      cid2 != cid4
      cid3 != cid6
