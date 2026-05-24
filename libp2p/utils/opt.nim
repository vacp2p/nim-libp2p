# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import results

func toOpt*[T](v: Opt[T] | T): Opt[T] =
  when v is T:
    Opt.some(v)
  else:
    v
