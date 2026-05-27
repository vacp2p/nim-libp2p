# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

proc safeConvert*[T: SomeInteger](value: SomeOrdinal): T =
  type S = typeof(value)
  ## Converts `value` from S to `T` iff `value` is guaranteed to be preserved.
  when int64(T.low) <= int64(S.low()) and uint64(T.high) >= uint64(S.high):
    T(value)
  else:
    {.error: "Source and target types have an incompatible range low..high".}
