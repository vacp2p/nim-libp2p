# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

when defined(libp2p_protobuf_metrics):
  import metrics
  export metrics

  declareCounter(
    libp2p_protobuf_bytes_received, "protobuf bytes received", labels = ["kind"]
  )
  declareCounter(libp2p_protobuf_bytes_sent, "protobuf bytes sent", labels = ["kind"])

  declareCounter(
    libp2p_protobuf_messages_received, "protobuf messages received", labels = ["kind"]
  )
  declareCounter(
    libp2p_protobuf_messages_sent, "protobuf messages sent", labels = ["kind"]
  )

  when defined(libp2p_testing):
    export
      libp2p_protobuf_bytes_received, libp2p_protobuf_bytes_sent,
      libp2p_protobuf_messages_received, libp2p_protobuf_messages_sent
