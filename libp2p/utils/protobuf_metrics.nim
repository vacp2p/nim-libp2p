# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

when defined(libp2p_protobuf_metrics):
  import metrics
  export metrics

  declareCounter(libp2p_protobuf_bytes_read, "protobuf bytes read", labels = ["kind"])
  declareCounter(libp2p_protobuf_bytes_write, "protobuf bytes write", labels = ["kind"])

  when defined(libp2p_testing):
    export libp2p_protobuf_bytes_read, libp2p_protobuf_bytes_write
