# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when defined(nimdoc):
  ## Welcome to the nim-libp2p reference!
  ##
  ## On the left, you'll find a switch that allows you to see private
  ## procedures. By default, you'll only see the public one (marked with `{.public.}`)
  ##
  ## The difference between public and private procedures is that public procedure
  ## stay backward compatible during the Major version, whereas private ones can
  ## change at each new Minor version.
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

  proc dummyPrivateProc*() =
    ## A private proc example
    discard

else:
  import
    libp2p/[
      protobuf/minprotobuf,
      muxers/muxer,
      muxers/mplex/mplex,
      stream/lpstream,
      stream/bufferstream,
      stream/connection,
      transports/transport,
      transports/tcptransport,
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

  export
    minprotobuf, switch, peerid, peerinfo, connection, multiaddress, crypto, lpstream,
    bufferstream, muxer, mplex, transport, tcptransport, noise, errors, cid, multihash,
    multicodec, builders, pubsub

  when defined(libp2p_quic_support):
    import libp2p/transports/quictransport
    export quictransport
