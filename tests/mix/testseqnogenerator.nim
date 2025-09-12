{.used.}

import chronicles, sets, unittest
import std/[os, times]
import ../../libp2p/peerid
include ../../libp2p/protocols/mix/seqno_generator

suite "Sequence Number Generator":
  test "init_seq_no_from_peer_id":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      seqNo = SeqNo.init(peerId)
    if seqNo.counter == 0:
      error "Sequence number initialization failed", counter = seqNo.counter
      fail()

  test "generate_seq_nos_for_different_messages":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      msg1 = @[byte 1, 2, 3]
      msg2 = @[byte 4, 5, 6]
    var seqNo = SeqNo.init(peerId)

    generateSeqNo(seqNo, msg1)
    let seqNo1 = seqNo.counter

    generateSeqNo(seqNo, msg2)
    let seqNo2 = seqNo.counter

    if seqNo1 == seqNo2:
      error "Sequence numbers for different messages should be different",
        seqNo1 = seqNo1, seqNo2 = seqNo2
      fail()

  test "generate_seq_nos_for_same_message":
    let
      peerId =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      msg = @[byte 1, 2, 3]
    var seqNo = SeqNo.init(peerId)

    generateSeqNo(seqNo, msg)
    let seqNo1 = seqNo.counter

    sleep(1000) # Wait for 1 second
    generateSeqNo(seqNo, msg)
    let seqNo2 = seqNo.counter

    if seqNo1 == seqNo2:
      error "Sequence numbers for same message at different times should be different",
        seqNo1 = seqNo1, seqNo2 = seqNo2
      fail()

  test "generate_seq_nos_for_different_peer_ids":
    let
      peerId1 =
        PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
      peerId2 =
        PeerId.init("16Uiu2HAm6WNzw8AssyPscYYi8x1bY5wXyQrGTShRH75bh5dPCjBQ").get()

    var
      seqNo1 = SeqNo.init(peerId1)
      seqNo2 = SeqNo.init(peerId2)

    if seqNo1.counter == seqNo2.counter:
      error "Sequence numbers for different peer IDs should be different",
        seqNo1 = seqNo1.counter, seqNo2 = seqNo2.counter
      fail()

  test "increment_seq_no":
    let peerId =
      PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
    var seqNo: SeqNo = SeqNo.init(peerId)
    let initialCounter = seqNo.counter

    incSeqNo(seqNo)

    if seqNo.counter != initialCounter + 1:
      error "Sequence number must be incremented exactly by one",
        initial = initialCounter, current = seqNo.counter
      fail()

  test "seq_no_wraps_around_at_max_value":
    let peerId =
      PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
    var seqNo = SeqNo.init(peerId)
    seqNo.counter = high(uint32) - 1
    if seqNo.counter != high(uint32) - 1:
      error "Sequence number must be max value",
        counter = seqNo.counter, maxval = high(uint32) - 1
      fail()

    incSeqNo(seqNo)
    if seqNo.counter != 0:
      error "Sequence number must wrap around", counter = seqNo.counter
      fail()

  test "generate_seq_no_uses_entire_uint32_range":
    let peerId =
      PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()
    var
      seqNo = SeqNo.init(peerId)
      seenValues = initHashSet[uint32]()

    for i in 0 ..< 10000:
      generateSeqNo(seqNo, @[byte i.uint8])
      seenValues.incl(seqNo.counter)

    if seenValues.len <= 9000:
      error "Sequence numbers must be uniformly distributed",
        uniqueValues = seenValues.len
      fail()
