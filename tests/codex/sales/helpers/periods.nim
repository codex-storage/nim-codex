import pkg/codex/market
import ../../helpers/mockclock

proc advanceToNextPeriod*(clock: MockClock, market: Market) {.async.} =
  let periodicity = await market.periodicity()
  let period = periodicity.periodOf(clock.now().u256)
  let periodEnd = periodicity.periodEnd(period)
  clock.set((periodEnd + 1).truncate(int))
