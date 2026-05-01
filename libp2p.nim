# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

when defined(nimdoc):
  ## Welcome to the nim-libp2p reference!
  ##
  ## If you're new to nim-libp2p, you can find a tutorial `here<https://vacp2p.github.io/nim-libp2p/docs/tutorial_1_connect/>`_
  ## that can help you get started.

  # Import stuff for doc
  import
    libp2p/[
      protobuf/minprotobuf,
      switch,
      stream/lpstream,
      builders,
      transports/tcptransport,
      transports/wstransport,
      protocols/ping,
      protocols/pubsub,
      peerid,
      peerinfo,
      peerstore,
      multiaddress,
    ]
else:
  import
    libp2p/[
      protobuf/minprotobuf,
      muxers/muxer,
      muxers/muxer_config,
      stream/lpstream,
      stream/bufferstream,
      stream/connection,
      transports/transport,
      transports/tcptransport,
      transports/quictransport,
      protocols/secure/noise,
      cid,
      multihash,
      multicodec,
      errors,
      switch,
      peerid,
      peerinfo,
      multiaddress,
      builders,
      crypto/crypto,
      protocols/pubsub,
    ]

  when MplexEnabled:
    import libp2p/muxers/mplex/mplex

  export
    minprotobuf, switch, peerid, peerinfo, connection, multiaddress, crypto, lpstream,
    bufferstream, muxer, muxer_config, transport, tcptransport, noise, errors, cid,
    multihash, multicodec, builders, pubsub, quictransport

  when MplexEnabled:
    export mplex
