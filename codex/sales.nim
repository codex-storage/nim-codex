import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/chronicles
import pkg/datastore
import ./market
import ./clock
import ./proving
import ./stores
import ./contracts/requests
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/slotqueue
import ./sales/states/preparing
import ./sales/states/unknown

## Sales holds a list of available storage that it may sell.
##
## When storage is requested on the market that matches availability, the Sales
## object will instruct the Codex node to persist the requested data. Once the
## data has been persisted, it uploads a proof of storage to the market in an
## attempt to win a storage contract.
##
##    Node                        Sales                   Market
##     |                          |                         |
##     | -- add availability  --> |                         |
##     |                          | <-- storage request --- |
##     | <----- store data ------ |                         |
##     | -----------------------> |                         |
##     |                          |                         |
##     | <----- prove data ----   |                         |
##     | -----------------------> |                         |
##     |                          | ---- storage proof ---> |

export stint
export reservations

logScope:
  topics = "sales"

type
  Sales* = ref object
    context*: SalesContext
    agents*: seq[SalesAgent]
    subscriptions: seq[Subscription]
    stopping: bool

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving,
          repo: RepoStore): Sales =

  Sales(
    context: SalesContext(
      market: market,
      clock: clock,
      proving: proving,
      reservations: Reservations.new(repo),
      slotQueue: SlotQueue.new()
    ),
    subscriptions: @[]
  )

proc remove(sales: Sales, agent: SalesAgent) {.async.} =
  await agent.stop()
  if not sales.stopping:
    sales.agents.keepItIf(it != agent)

proc cleanUp(sales: Sales,
             agent: SalesAgent,
             processing: Future[void]) {.async.} =
  await sales.remove(agent)
  # signal back to the slot queue to cycle a worker
  processing.complete()

proc handleRequest(sales: Sales, item: SlotQueueItem, processing: Future[void]) =
  debug "handling storage requested", requestId = $item.requestId,
    slot = item.slotIndex

  let agent = newSalesAgent(
    sales.context,
    item.requestId,
    item.slotIndex.u256,
    none StorageRequest
  )

  agent.context.onCleanUp = proc {.async.} =
    await sales.cleanUp(agent, processing)

  agent.start(SalePreparing())
  sales.agents.add agent

proc mySlots*(sales: Sales): Future[seq[Slot]] {.async.} =
  let market = sales.context.market
  let slotIds = await market.mySlots()
  var slots: seq[Slot] = @[]

  for slotId in slotIds:
    if slot =? (await market.getActiveSlot(slotId)):
      slots.add slot

  return slots

proc load*(sales: Sales) {.async.} =
  let slots = await sales.mySlots()

  for slot in slots:
    let agent = newSalesAgent(
      sales.context,
      slot.request.id,
      slot.slotIndex,
      some slot.request)

    agent.context.onCleanUp = proc {.async.} = await sales.remove(agent)

    agent.start(SaleUnknown())
    sales.agents.add agent

proc subscribeRequested(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market

  proc onRequestEvent(requestId: RequestId,
                      ask: StorageAsk,
                      expiry: UInt256) {.gcsafe, upraises:[].} =
    try:
      let reservations = context.reservations
      let slotQueue = context.slotQueue
      # Match availability before pushing. If availabilities weren't matched,
      # every request in the network would get added to the slot queue.
      # However, matching availabilities requires the subscription callback to
      # be async, which has been avoided on many occasions, so we are using
      # `waitFor`.
      if availability =? waitFor reservations.find(ask.slotSize,
                                                   ask.duration,
                                                   ask.pricePerSlot,
                                                   ask.collateral,
                                                   used = false):
        let items = SlotQueueItem.init(requestId, ask, expiry)
        if err =? slotQueue.push(items).errorOption:
          raise err
    except CatchableError as e:
      warn "Error pushing request to SlotQueue", error = e.msg
      discard

  try:
    let sub = await market.subscribeRequests(onRequestEvent)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to storage request events", msg = e.msg

proc subscribeCancellation(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onCancelled(requestId: RequestId) =
    queue.delete(requestId)

  try:
    let sub = await market.subscribeRequestCancelled(onCancelled)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to cancellation events", msg = e.msg

proc subscribeFulfilled*(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onFulfilled(requestId: RequestId) =
    queue.delete(requestId)

    for agent in sales.agents:
      try:
        agent.onFulfilled(requestId)
      except Exception as e:
        # raised from dynamic dispatch
        error "Error during sales agent onFulfilled callback", error = e.msg

  try:
    let sub = await market.subscribeFulfillment(onFulfilled)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to storage fulfilled events", msg = e.msg

proc subscribeFailure(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onFailed(requestId: RequestId) =
    queue.delete(requestId)

    for agent in sales.agents:
      agent.onFailed(requestId)

  try:
    let sub = await market.subscribeRequestFailed(onFailed)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to storage failure events", msg = e.msg

proc subscribeSlotFilled(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
    queue.delete(requestId, slotIndex.truncate(uint64))

    for agent in sales.agents:
      try:
        agent.onSlotFilled(requestId, slotIndex)
      except Exception as e:
        # raised from dynamic dispatch
        error "Error during sales agent onSlotFilled callback", error = e.msg

  try:
    let sub = await market.subscribeSlotFilled(onSlotFilled)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to slot filled events", msg = e.msg

proc subscribeSlotFreed(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onSlotFreed(requestId: RequestId,
                   slotIndex: UInt256) {.gcsafe, upraises: [].} =

    try:
      # retrieving the request requires the subscription callback to be async,
      # which has been avoided on many occasions, so we are using `waitFor`.
      if request =? waitFor market.getRequest(requestId):
        let item = SlotQueueItem.init(request, slotIndex.truncate(uint64))
        if err =? queue.push(item).errorOption:
          error "Error adding slot index to slot queue", error = err.msg

      else:
        # contract doesn't seem to know about this request, so remove it from
        # the queue
        queue.delete(requestId)
    except CatchableError, Exception:
      let e = getCurrentException()
      error "Exception during sales slot freed event handler", error = e.msg

  try:
    let sub = await market.subscribeSlotFreed(onSlotFreed)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to slot freed events", msg = e.msg

proc startSlotQueue(sales: Sales) {.async.} =
  let slotQueue = sales.context.slotQueue
  slotQueue.onProcessSlot =
    proc(item: SlotQueueItem, processing: Future[void]) {.async.} =
      sales.handleRequest(item, processing)
  asyncSpawn slotQueue.start()

proc subscribe(sales: Sales) {.async.} =
  await sales.subscribeRequested()
  await sales.subscribeFulfilled()
  await sales.subscribeFailure()
  await sales.subscribeSlotFilled()
  await sales.subscribeSlotFreed()
  await sales.subscribeCancellation()

proc unsubscribe(sales: Sales) {.async.} =
  let subs = sales.subscriptions
  for sub in sales.subscriptions:
    try:
      await sub.unsubscribe()
    except CatchableError as e:
      error "Unable to unsubscribe from subscription", error = e.msg

proc start*(sales: Sales) {.async.} =
  await sales.startSlotQueue()
  await sales.subscribe()

proc stop*(sales: Sales) {.async.} =
  sales.stopping = true
  sales.context.slotQueue.stop()
  await sales.unsubscribe()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]
  sales.stopping = false
