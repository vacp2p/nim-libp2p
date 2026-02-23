# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import metrics

export metrics

# Message metrics
declarePublicCounter kad_messages_sent, "kad messages sent", ["type"]
declarePublicCounter kad_messages_received, "kad messages received", ["type"]
declarePublicCounter kad_message_bytes_sent, "kad message bytes sent", ["type"]
declarePublicCounter kad_message_bytes_received, "kad message bytes received", ["type"]
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
