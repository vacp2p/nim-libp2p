{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import stew/byteutils
import ../libp2p/multicodec
import ../libp2p/multiaddress
import ../libp2p/transcoder

suite "MutliAddress regisration":

  proc ma1StB(s: string, vb: var VBuffer): bool =
    try:
      vb.writeArray("test".toBytes())
      result = true
    except CatchableError:
      discard

  proc ma1BtS(vb: var VBuffer, s: var string): bool =
    if vb.readArray(s) == 4 and s == "test":
      result = true

  proc ma1VB(vb: var VBuffer): bool =
    var temp: string
    if vb.readArray(temp) == 4 and temp == "test":
      result = true

  const
    TranscoderMA1 =
      Transcoder(stringToBuffer: ma1StB, bufferToString: ma1BtS, validateBuffer: ma1VB)

  registerMultiCodecs:
    ("codec_ma1", 0xFF06)
    ("codec_ma2", 0xFF07)

  registerProtocols:
    MAProtocol(mcodec: multiCodec("codec_ma1"), kind: Fixed, size: 4, coder: TranscoderMA1)
    MAProtocol(mcodec: multiCodec("codec_ma2"), kind: Fixed, size: 0)
    MAProtocol(mcodec: multiCodec("ip4"), kind: Fixed, size: 4, coder: TranscoderMA1)

  test "does not allow registering anything other than MAProtocol objects":
    type NotAnMProtocol {.used.} = object
      x: int

    check:
      not compiles(block:
        registerProtocols:
          NotAnMHash(x: 1)
      )

  test "registered protocols can be correctly initialized":
    var data = cast[seq[byte]]("hello")
    let ma1Init = MultiAddress.init("/codec_ma1/test").get()
    let ma2Init = MultiAddress.init("/codec_ma2/test").get()

    check:
      $ma1Init == "/codec_ma1/test"
      $ma2Init == "/codec_ma2/test"

  # test "can initialise registered MultiHashes":
  #   var data = cast[seq[byte]]("hello")
  #   let mh1 = MultiHash.digest("codec_mh1", data).get
  #   let mh2 = MultiHash.digest("codec_mh2", data).get
  #   let expected1 = "84FE030568656C6C6F"
  #   let expected2 = "85FE030668656C6C6F00"
  #   let mhInit1 = MultiHash.init(expected1).get
  #   let mhInit2 = MultiHash.init(expected2).get

  #   check:
  #     mhInit1 == mh1
  #     mhInit2 == mh2
  #     mhInit1.mcodec == multiCodec("codec_mh1")
  #     mhInit2.mcodec == multiCodec("codec_mh2")
  #     mhInit1.size == 5
  #     mhInit2.size == 6
  #     mhInit1.data.len == 9
  #     mhInit2.data.len == 10
  #     mhInit1.dpos == 4
  #     mhInit2.dpos == 4

  # test "can register an overriding hash function for already registered hash":
  #   # The first "sha2-256" registration is registered in the multihash module,
  #   # which uses sha2-256 coder for hashing. Above, we have registered a new
  #   # "sha2-256" which uses `sha2_256_override` for hashing.
  #   var data = cast[seq[byte]]("hello")
  #   let mh = MultiHash.digest("sha2-256", data).get
  #   let expected_orig = "12202CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"
  #   let expected_override = "120668656C6C6F00"

  #   check:
  #     mh.hex == expected_override
  #     mh.hex != expected_orig
