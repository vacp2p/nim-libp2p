# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

when defined(linux) and defined(amd64):
  import test_autotls_integration, test_peer_id_auth_integration, test_ws_integration
