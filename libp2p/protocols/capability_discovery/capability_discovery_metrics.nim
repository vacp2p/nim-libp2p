# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import metrics

export metrics

# Message metrics
declarePublicCounter cd_messages_sent, "capability discovery messages sent", ["type"]
declarePublicCounter cd_messages_received,
  "capability discovery messages received", ["type"]
declarePublicCounter cd_message_bytes_sent,
  "capability discovery message bytes sent", ["type"]
declarePublicCounter cd_message_bytes_received,
  "capability discovery message bytes received", ["type"]
declarePublicHistogram cd_message_duration_ms,
  "capability discovery message round trip duration in milliseconds",
  ["type"],
  buckets = [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0, 5000.0, 10000.0]

# Registration metrics
declarePublicCounter cd_register_responses,
  "registration responses received", ["status"]
declarePublicCounter cd_register_requests, "registration requests handled", ["status"]

# Lookup metrics
declarePublicCounter cd_lookup_requests, "capability lookup requests initiated"
declarePublicCounter cd_lookup_peers_found, "peers found during capability lookup"

# Registrar cache metrics
declarePublicGauge cd_registrar_cache_ads, "total advertisements in registrar cache"
declarePublicGauge cd_registrar_cache_services, "number of services in registrar cache"
declarePublicCounter cd_registrar_ads_expired,
  "advertisements expired from registrar cache"

# Service routing tables metrics
declarePublicGauge cd_service_tables_count, "number of service routing tables"
declarePublicGauge cd_service_table_peers, "total peers across all service tables"
declarePublicCounter cd_service_table_insertions,
  "peer insertions into service routing tables"

# IpTree metrics
declarePublicGauge cd_iptree_unique_ips, "unique IPs tracked in the IP tree"

# Advertiser metrics
declarePublicGauge cd_advertiser_pending_actions,
  "pending registration actions in queue"
declarePublicCounter cd_advertiser_actions_executed, "registration actions executed"
declarePublicCounter cd_advertiser_services_added, "services added for advertisement"
declarePublicCounter cd_advertiser_services_removed,
  "services removed from advertisement"
