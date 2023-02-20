import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ./states/[cancelled, downloading, errored, failed, finished, filled,
                 filling, proving, unknown]
import ../contracts/requests

proc newSalesAgent*(sales: Sales,
                    slotIndex: UInt256,
                    availability: ?Availability,
                    request: StorageRequest,
                    me: Address,
                    requestState: RequestState,
                    slotState: SlotState,
                    restoredFromChain: bool): SalesAgent =
  let agent = SalesAgent.new(@[
    Transition.new(
      SaleUnknown.new(),
      SaleDownloading.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        agent.requestState.value == RequestState.New and
        agent.slotState.value == SlotState.Free
    ),
    Transition.new(
      AnyState.new(),
      SaleCancelled.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).requestState.value == RequestState.Cancelled
    ),
    Transition.new(
      AnyState.new(),
      SaleFailed.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        agent.requestState.value == RequestState.Failed or
        agent.slotState.value == SlotState.Failed
    ),
    Transition.new(
      AnyState.new(),
      SaleFilled.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).slotState.value == SlotState.Filled
    ),
    Transition.new(
      AnyState.new(),
      SaleFinished.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        agent.slotState.value in @[SlotState.Finished, SlotState.Paid] or
        agent.requestState.value == RequestState.Finished
    ),
    Transition.new(
      AnyState.new(),
      SaleErrored.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).errored.value
    ),
    Transition.new(
      SaleDownloading.new(),
      SaleProving.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).downloaded.value
    ),
    Transition.new(
      SaleProving.new(),
      SaleFilling.new(),
      proc(m: Machine, s: State): bool =
        SalesAgent(m).proof.value.len > 0 # TODO: proof validity check?
    ),
    Transition.new(
      SaleFilled.new(),
      SaleFinished.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        without host =? agent.slotHost.value:
          return false
        host == agent.me
    ),
    Transition.new(
      SaleFilled.new(),
      SaleErrored.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        without host =? agent.slotHost.value:
          return false
        if host != agent.me:
          agent.lastError = newException(HostMismatchError,
            "Slot filled by other host")
          return true
        else: return false
    ),
    Transition.new(
      SaleUnknown.new(),
      SaleErrored.new(),
      proc(m: Machine, s: State): bool =
        let agent = SalesAgent(m)
        if agent.restoredFromChain and agent.slotState.value == SlotState.Free:
          agent.lastError = newException(SaleUnknownError,
            "cannot retrieve slot state")
          return true
        else: return false
    ),
  ])
  agent.slotState = agent.newTransitionProperty(slotState)
  agent.requestState = agent.newTransitionProperty(requestState)
  agent.proof = agent.newTransitionProperty(newSeq[byte]())
  agent.slotHost = agent.newTransitionProperty(none Address)
  agent.downloaded = agent.newTransitionProperty(false)
  agent.sales = sales
  agent.availability = availability
  agent.slotIndex = slotIndex
  agent.request = request
  agent.me = me
  return agent

proc subscribeCancellation*(agent: SalesAgent): Future[void] {.gcsafe.}
proc subscribeFailure*(agent: SalesAgent): Future[void] {.gcsafe.}
proc subscribeSlotFill*(agent: SalesAgent): Future[void] {.gcsafe.}

proc start*(agent: SalesAgent, initialState: State) {.async.} =
  await agent.subscribeCancellation()
  await agent.subscribeFailure()
  await agent.subscribeSlotFill()
  procCall Machine(agent).start(initialState)

proc stop*(agent: SalesAgent) {.async.} =
  try:
    await agent.subscribeFulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.subscribeFailed.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.subscribeSlotFilled.unsubscribe()
  except CatchableError:
    discard
  if not agent.waitForCancelled.completed:
    await agent.waitForCancelled.cancelAndWait()

  procCall Machine(agent).stop()

proc subscribeCancellation*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onCancelled() {.async.} =
    let clock = agent.sales.clock

    await clock.waitUntil(agent.request.expiry.truncate(int64))
    await agent.subscribeFulfilled.unsubscribe()
    agent.requestState.setValue(RequestState.Cancelled)

  agent.waitForCancelled = onCancelled()

  proc onFulfilled(_: RequestId) =
    agent.waitForCancelled.cancel()

  agent.subscribeFulfilled =
    await market.subscribeFulfillment(agent.request.id, onFulfilled)

# TODO: move elsewhere
proc asyncSpawn(future: Future[void], ignore: type CatchableError) =
  proc ignoringError {.async.} =
    try:
      await future
    except ignore:
      discard
  asyncSpawn ignoringError()

proc subscribeFailure*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onFailed(_: RequestId) {.upraises:[], gcsafe.} =
    asyncSpawn agent.subscribeFailed.unsubscribe(), ignore = CatchableError
    try:
      agent.requestState.setValue(RequestState.Failed)
    except AsyncQueueFullError as e:
      raiseAssert "State machine critical failure: " & e.msg

  agent.subscribeFailed =
    await market.subscribeRequestFailed(agent.request.id, onFailed)

proc subscribeSlotFill*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onSlotFilled(
    requestId: RequestId,
    slotIndex: UInt256) {.upraises:[], gcsafe.} =

    let market = agent.sales.market

    asyncSpawn agent.subscribeSlotFilled.unsubscribe(), ignore = CatchableError
    try:
      agent.slotState.setValue(SlotState.Filled)
    except AsyncQueueFullError as e:
      raiseAssert "State machine critical failure: " & e.msg

  agent.subscribeSlotFilled =
    await market.subscribeSlotFilled(agent.request.id,
                                    agent.slotIndex,
                                    onSlotFilled)

