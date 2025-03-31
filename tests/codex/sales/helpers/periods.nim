import pkg/codex/market
import ../../helpers/mockclock

proc advanceToNextPeriod*(clock: MockClock, market: Market) =
  let periodicity = market.periodicity()
  let period = periodicity.periodOf(clock.now())
  let periodEnd = periodicity.periodEnd(period)
  clock.set(periodEnd.toSecondsSince1970 + 1)
