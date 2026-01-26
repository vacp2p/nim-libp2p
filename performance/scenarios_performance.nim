# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import unittest2
import ./runner

setupOutputDirectory()

suite "Performance Tests":
  test "Base Test TCP":
    run("Base Test", "TCP")

  test "Base Test QUIC":
    run("Base Test", "QUIC")
