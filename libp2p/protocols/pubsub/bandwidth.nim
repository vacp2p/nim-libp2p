import std/atomics

const defaultAlpha = 0.3

type
  ExponentialMovingAverage* = object
    alpha: float
    value: float
    accum: Atomic[int]

  BandwidthTracking* = ref object
    upload*: ExponentialMovingAverage
    download*: ExponentialMovingAverage

proc init*(
    T: type[ExponentialMovingAverage], alpha: float = defaultAlpha
): ExponentialMovingAverage =
  ExponentialMovingAverage(alpha: alpha, value: 0.0)

proc init*(T: type[BandwidthTracking], alpha: float = defaultAlpha): BandwidthTracking =
  BandwidthTracking(
    upload: ExponentialMovingAverage.new(), download: ExponentialMovingAverage.new()
  )

proc update(e: var ExponentialMovingAverage) =
  let sample = e.accum.exchange(0)
  e.value = e.alpha * float(sample) + (1.0 - e.alpha) * e.value

proc track*(e: var ExponentialMovingAverage, bytes: int) =
  e.accum.atomicInc(bytes)

proc value*(e: var ExponentialMovingAverage): float =
  e.value

proc update*(b: var BandwidthTracking) =
  b.upload.update()
  b.download.update()
