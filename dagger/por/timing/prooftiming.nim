import pkg/chronos
import pkg/stint
import ./periods

export chronos
export stint
export periods

type
  ProofTiming* = ref object of RootObj

method periodicity*(proofTiming: ProofTiming):
                   Future[Periodicity] {.base, async.} =
  raiseAssert("not implemented")

method waitUntilNextPeriod*(proofTiming: ProofTiming) {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(proofTiming: ProofTiming): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

func periodOf*(periodicity: Periodicity, timestamp: Timestamp): Period =
  timestamp div periodicity.seconds

func periodStart*(periodicity: Periodicity, period: Period): Timestamp =
  period * periodicity.seconds

func periodEnd*(periodicity: Periodicity, period: Period): Timestamp =
  periodicity.periodStart(period + 1)
