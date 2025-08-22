{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos
import
  ../libp2p/[
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonatv2/core,
      # nameresolving/nameresolver,
      # nameresolving/mockresolver,
  ],
  ./helpers

suite "AutonatV2":
  teardown:
    checkTrackers()

  asyncTest "encode/decode messages":
    # DialRequest
    let dialReq = DialRequest(
      addrs:
        @[
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
        ],
      nonce: 42,
    )
    let encodedReq = dialReq.encode()
    let decodedReq = DialRequest.decode(encodedReq).get()
    check:
      decodedReq.addrs == dialReq.addrs
      decodedReq.nonce == dialReq.nonce

    # DialResponse
    let dialResp =
      DialResponse(status: ResponseStatus.Ok, addrIdx: 1, dialStatus: DialStatus.Ok)
    let encodedResp = dialResp.encode()
    let decodedResp = DialResponse.decode(encodedResp).get()
    check:
      decodedResp.status == dialResp.status
      decodedResp.addrIdx == dialResp.addrIdx
      decodedResp.dialStatus == dialResp.dialStatus

    # DialDataRequest
    let dataReq = DialDataRequest(addrIdx: 0, numBytes: 128)
    let encodedDataReq = dataReq.encode()
    let decodedDataReq = DialDataRequest.decode(encodedDataReq).get()
    check:
      decodedDataReq.addrIdx == dataReq.addrIdx
      decodedDataReq.numBytes == dataReq.numBytes

    # DialDataResponse
    let dataResp = DialDataResponse(data: @[1'u8, 2, 3, 4, 5])
    let encodedDataResp = dataResp.encode()
    let decodedDataResp = DialDataResponse.decode(encodedDataResp).get()
    check:
      decodedDataResp.data == dataResp.data

    # AutonatV2Msg - DialRequest
    let msgReq = AutonatV2Msg(msgType: MsgType.DialRequest, dialReq: dialReq)
    let encodedMsgReq = msgReq.encode()
    let decodedMsgReq = AutonatV2Msg.decode(encodedMsgReq).get()
    check:
      decodedMsgReq.msgType == MsgType.DialRequest
      decodedMsgReq.dialReq.addrs == dialReq.addrs
      decodedMsgReq.dialReq.nonce == dialReq.nonce

    # AutonatV2Msg - DialResponse
    let msgResp = AutonatV2Msg(msgType: MsgType.DialResponse, dialResp: dialResp)
    let encodedMsgResp = msgResp.encode()
    let decodedMsgResp = AutonatV2Msg.decode(encodedMsgResp).get()
    check:
      decodedMsgResp.msgType == MsgType.DialResponse
      decodedMsgResp.dialResp.status == dialResp.status
      decodedMsgResp.dialResp.addrIdx == dialResp.addrIdx
      decodedMsgResp.dialResp.dialStatus == dialResp.dialStatus

    # AutonatV2Msg - DialDataRequest
    let msgDataReq =
      AutonatV2Msg(msgType: MsgType.DialDataRequest, dialDataReq: dataReq)
    let encodedMsgDataReq = msgDataReq.encode()
    let decodedMsgDataReq = AutonatV2Msg.decode(encodedMsgDataReq).get()
    check:
      decodedMsgDataReq.msgType == MsgType.DialDataRequest
      decodedMsgDataReq.dialDataReq.addrIdx == dataReq.addrIdx
      decodedMsgDataReq.dialDataReq.numBytes == dataReq.numBytes

    # AutonatV2Msg - DialDataResponse
    let msgDataResp =
      AutonatV2Msg(msgType: MsgType.DialDataResponse, dialDataResp: dataResp)
    let encodedMsgDataResp = msgDataResp.encode()
    let decodedMsgDataResp = AutonatV2Msg.decode(encodedMsgDataResp).get()
    check:
      decodedMsgDataResp.msgType == MsgType.DialDataResponse
      decodedMsgDataResp.dialDataResp.data == dataResp.data

    # DialBack
    let dialBack = DialBack(nonce: 123456)
    let encodedBack = dialBack.encode()
    let decodedBack = DialBack.decode(encodedBack).get()
    check:
      decodedBack.nonce == dialBack.nonce

    # DialBackResponse
    let dialBackResp = DialBackResponse(status: DialBackStatus.Ok)
    let encodedBackResp = dialBackResp.encode()
    let decodedBackResp = DialBackResponse.decode(encodedBackResp).get()
    check:
      decodedBackResp.status == dialBackResp.status
