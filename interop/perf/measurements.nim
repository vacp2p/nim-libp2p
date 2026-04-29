# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import algorithm, chronos, math, sequtils, strformat, strutils
import
  ../../libp2p/
    [builders, protocols/perf/client, protocols/perf/core, protocols/perf/server]

type MeasurementStats* = object
  min*: float
  q1*: float
  median*: float
  q3*: float
  max*: float
  outliers*: seq[float]
  samples*: seq[float]

proc percentile(sortedValues: seq[float], p: float): float =
  if sortedValues.len == 0:
    return 0.0

  let index = (p / 100.0) * float(sortedValues.len - 1)
  let lower = int(floor(index))
  let upper = int(ceil(index))

  if lower == upper:
    return sortedValues[lower]

  let weight = index - float(lower)
  sortedValues[lower] * (1.0 - weight) + sortedValues[upper] * weight

proc calculateStats*(values: seq[float]): MeasurementStats =
  if values.len == 0:
    return MeasurementStats()

  var samples = values
  samples.sort()

  let
    q1 = percentile(samples, 25.0)
    median = percentile(samples, 50.0)
    q3 = percentile(samples, 75.0)
    iqr = q3 - q1
    lowerFence = q1 - 1.5 * iqr
    upperFence = q3 + 1.5 * iqr

  var
    outliers: seq[float]
    nonOutliers: seq[float]

  for value in samples:
    if value < lowerFence or value > upperFence:
      outliers.add(value)
    else:
      nonOutliers.add(value)

  let filtered = if nonOutliers.len > 0: nonOutliers else: samples

  MeasurementStats(
    min: filtered[0],
    q1: q1,
    median: median,
    q3: q3,
    max: filtered[^1],
    outliers: outliers,
    samples: samples,
  )

proc formatList(values: seq[float], decimals: int): string =
  if values.len == 0:
    return "[]"

  "[" & values.mapIt(formatFloat(it, ffDecimal, decimals)).join(", ") & "]"

proc printMeasurement*(
    name: string, iterations: int, stats: MeasurementStats, decimals: int, unit: string
) =
  echo name & ":"
  echo &"  iterations: {iterations}"
  echo &"  min: {formatFloat(stats.min, ffDecimal, decimals)}"
  echo &"  q1: {formatFloat(stats.q1, ffDecimal, decimals)}"
  echo &"  median: {formatFloat(stats.median, ffDecimal, decimals)}"
  echo &"  q3: {formatFloat(stats.q3, ffDecimal, decimals)}"
  echo &"  max: {formatFloat(stats.max, ffDecimal, decimals)}"
  echo "  outliers: " & formatList(stats.outliers, decimals)
  echo "  samples: " & formatList(stats.samples, decimals)
  echo "  unit: " & unit

proc measurementValue*(
    uploadBytes: uint64, downloadBytes: uint64, duration: Duration
): float =
  # Transfers above 100 bytes are throughput measurements (report Gbps);
  # <= 100 bytes are latency measurements (report milliseconds).
  # Same convention as the go-libp2p reference perf impl.
  if uploadBytes > 100'u64 or downloadBytes > 100'u64:
    let
      transferredBytes = max(uploadBytes, downloadBytes)
      seconds = max(float(duration.microseconds()) / 1_000_000.0, 1e-9)
    return (float(transferredBytes) * 8.0) / seconds / 1_000_000_000.0

  float(duration.microseconds()) / 1_000.0

proc runMeasurement*(
    sw: Switch,
    remotePeerId: PeerId,
    uploadBytes: uint64,
    downloadBytes: uint64,
    iterations: int,
): Future[MeasurementStats] {.async.} =
  var values: seq[float]
  let perfClient = PerfClient.new()

  for iteration in 0 ..< iterations:
    let
      startedAt = Moment.now()
      conn = await sw.dial(remotePeerId, PerfCodec)

    try:
      discard await perfClient.perf(conn, uploadBytes, downloadBytes)
      values.add(measurementValue(uploadBytes, downloadBytes, Moment.now() - startedAt))
    finally:
      await conn.close()

  calculateStats(values)

proc mountPerf*(sw: Switch) =
  sw.mount(Perf.new())
