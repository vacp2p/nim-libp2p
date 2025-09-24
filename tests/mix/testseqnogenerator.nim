{.used.}

import chronicles, sets, unittest
import std/[os, times]
import ../../libp2p/peerid
include ../../libp2p/protocols/mix/seqno_generator

const second = 1000

suite "Sequence Number Generator":
  test "init_seq_no_from_peer_id":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      seqNo = SeqNo.init(peerId)

    check seqNo != 0

  test "generate_seq_nos_for_different_messages":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      msg1 = @[byte 1, 2, 3]
      msg2 = @[byte 4, 5, 6]

    var seqNo = SeqNo.init(peerId)

    seqNo.generate(msg1)
    let seqNo1 = seqNo

    seqNo.generate(msg2)
    let seqNo2 = seqNo

    check seqNo1 != seqNo2

  test "generate_seq_nos_for_same_message":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      msg = @[byte 1, 2, 3]
    var seqNo = SeqNo.init(peerId)

    seqNo.generate(msg)
    let seqNo1 = seqNo

    sleep(second)

    seqNo.generate(msg)
    let seqNo2 = seqNo

    check seqNo1 != seqNo2

  test "generate_seq_nos_for_different_peer_ids":
    let
      peerId1 =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      peerId2 =
        PeerId.init("16Uiu2HAm6WNzw8AssyPscYYi8x1bY5wXyQrGTShRH75bh5dPCjBQ").get()

    var
      seqNo1 = SeqNo.init(peerId1)
      seqNo2 = SeqNo.init(peerId2)

    check seqNo1 != seqNo2

  test "increment_seq_no":
    let peerId =
      PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
    var seqNo: SeqNo = SeqNo.init(peerId)
    let initialCounter = seqNo

    seqNo.inc()

    check seqNo == initialCounter + 1

  test "seq_no_wraps_around_at_max_value":
    var seqNo = high(uint32) - 1

    seqNo.inc()

    check seqNo == 0

  test "generate_seq_no_uses_entire_uint32_range":
    let peerId =
      PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
    var
      seqNo = SeqNo.init(peerId)
      seenValues = initHashSet[uint32]()

    for i in 0 ..< 10000:
      seqNo.generate(@[i.uint8])
      seenValues.incl(seqNo)

    check seenValues.len > 9000
