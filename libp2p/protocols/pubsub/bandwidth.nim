import chronos
import std/atomics

const DefaultAlpha = 0.3
const InitialRate = 2_500_000 #bytes per second

type
  ExponentialMovingAverage* = ref object
    alpha: float
    value: Atomic[float64]

  BandwidthTracking* = ref object
    download*: ExponentialMovingAverage

proc init*(T: type[ExponentialMovingAverage], alpha: float = DefaultAlpha): T =
  let e = ExponentialMovingAverage(alpha: alpha)
  e.value.store(InitialRate)
  return e

proc init*(T: type[BandwidthTracking], alpha: float = DefaultAlpha): T =
  BandwidthTracking(download: ExponentialMovingAverage())

proc update*(e: var ExponentialMovingAverage, startAt: Moment, bytes: int) =
  let elapsedTime = Moment.now() - startAt
  let curSample = float(bytes * 1000) / elapsedTime.milliseconds.float
  let oldSample = e.value.load()
  let ema = e.alpha * curSample + (1.0 - e.alpha) * oldSample
  e.value.store(ema)

proc value*(e: var ExponentialMovingAverage): float =
  e.value.load()

proc calculateReceiveTimeMs*(msgLen: int64, dataRate: int64 = InitialRate): int64 =
  let txTime = ((msgLen * 1000) div dataRate)
  #ideally (RTT * 2) + 5% TxTime ? Need many testruns to precisely adjust safety margin
  let margin = 250 + (txTime.float64 * 0.05)
  result = txTime + margin.int64
