# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import metrics

export metrics

declarePublicGauge libp2p_relay_reservations_active, "active circuit-relay reservations"
declarePublicCounter libp2p_relay_reservation_attempts,
  "circuit-relay reservation attempts", ["result"]
declarePublicGauge libp2p_relay_circuits_active, "active circuit-relay circuits"
declarePublicCounter libp2p_relay_connections,
  "circuit-relay connection attempts", ["result"]
declarePublicCounter libp2p_relay_bytes,
  "bytes forwarded by circuit relay", ["direction"]
