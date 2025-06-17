import chronos
import std/atomics

const defaultAlpha = 0.3
const initialRate = 2_500_000.0 #bytes per second

type
  ExponentialMovingAverage* = ref object
    alpha: float
    value: Atomic[float64]

  BandwidthTracking* = ref object
    download*: ExponentialMovingAverage

proc init*(
    T: type[ExponentialMovingAverage], alpha: float = defaultAlpha
): ExponentialMovingAverage =
  let e = ExponentialMovingAverage(alpha: alpha)
  e.value.store(initialRate)
  return e

proc init*(T: type[BandwidthTracking], alpha: float = defaultAlpha): BandwidthTracking =
  BandwidthTracking(download: ExponentialMovingAverage())

proc update*(e: var ExponentialMovingAverage, startAt: Moment, bytes: int) =
  let elapsedTime = Moment.now() - startAt
  let curSample = (bytes * 1000) / elapsedTime.milliseconds
  let oldSample = e.value.load()
  let ema = e.alpha * float(curSample) + (1.0 - e.alpha) * oldSample
  e.value.store(ema)

proc value*(e: var ExponentialMovingAverage): float =
  e.value.load()
