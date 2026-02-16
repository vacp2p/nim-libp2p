# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

when defined(libp2p_kad_metrics):
  import metrics
  import chronos

  export metrics

  # Message metrics
  declarePublicCounter kad_messages_sent, "kad messages sent", ["type"]
  declarePublicCounter kad_messages_received, "kad messages received", ["type"]
  declarePublicCounter kad_message_bytes_sent, "kad message bytes sent", ["type"]
  declarePublicCounter kad_message_bytes_received,
    "kad message bytes received", ["type"]
  declarePublicHistogram kad_message_duration_ms,
    "kad message round trip duration in milliseconds",
    ["type"],
    buckets = [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0, 5000.0, 10000.0]
  declarePublicCounter kad_responses_with_closer_peers,
    "responses with closer peers", ["type"]

  # Routing table metrics
  declarePublicGauge kad_routing_table_peers, "total peers in routing table"
  declarePublicGauge kad_routing_table_buckets, "number of buckets"
  declarePublicGauge kad_routing_table_bucket_size, "peers per bucket", ["bucket"]
  declarePublicCounter kad_routing_table_insertions, "peer insertions"
  declarePublicCounter kad_routing_table_replacements, "peer replacements"

  proc toFloatMs*(d: Duration): float64 =
    d.nanoseconds.float64 / 1_000_000.0

else:
  # No-op stubs when metrics disabled
  import chronos

  type
    kad_messages_sent* = object
    kad_messages_received* = object
    kad_message_bytes_sent* = object
    kad_message_bytes_received* = object
    kad_message_duration_ms* = object
    kad_responses_with_closer_peers* = object
    kad_routing_table_peers* = object
    kad_routing_table_buckets* = object
    kad_routing_table_bucket_size* = object
    kad_routing_table_insertions* = object
    kad_routing_table_replacements* = object

  template inc*(
      x: typedesc[kad_messages_sent] | kad_messages_sent,
      labelValues: openArray[string] = [],
  ) =
    discard

  template inc*(
      x: typedesc[kad_messages_received] | kad_messages_received,
      labelValues: openArray[string] = [],
  ) =
    discard

  template inc*(
      x: typedesc[kad_message_bytes_sent] | kad_message_bytes_sent,
      v: int64,
      labelValues: openArray[string] = [],
  ) =
    discard

  template inc*(
      x: typedesc[kad_message_bytes_received] | kad_message_bytes_received,
      v: int64,
      labelValues: openArray[string] = [],
  ) =
    discard

  template observe*(
      x: typedesc[kad_message_duration_ms] | kad_message_duration_ms,
      v: float64,
      labelValues: openArray[string] = [],
  ) =
    discard

  template inc*(
      x: typedesc[kad_responses_with_closer_peers] | kad_responses_with_closer_peers,
      labelValues: openArray[string] = [],
  ) =
    discard

  template set*(
      x: typedesc[kad_routing_table_peers] | kad_routing_table_peers, v: float64
  ) =
    discard

  template set*(
      x: typedesc[kad_routing_table_buckets] | kad_routing_table_buckets, v: float64
  ) =
    discard

  template set*(
      x: typedesc[kad_routing_table_bucket_size] | kad_routing_table_bucket_size,
      v: float64,
      labelValues: openArray[string] = [],
  ) =
    discard

  template inc*(
      x: typedesc[kad_routing_table_insertions] | kad_routing_table_insertions
  ) =
    discard

  template inc*(
      x: typedesc[kad_routing_table_replacements] | kad_routing_table_replacements
  ) =
    discard

  proc toFloatMs*(d: Duration): float64 =
    d.nanoseconds.float64 / 1_000_000.0
