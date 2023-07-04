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

  let reservations = Reservations.new(repo)
  Sales(
    context: SalesContext(
      market: market,
      clock: clock,
      proving: proving,
      reservations: reservations,
      slotQueue: SlotQueue.new(reservations)
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
  if not processing.isNil and not processing.finished():
    processing.complete()

proc handleRequest(sales: Sales, item: SlotQueueItem) =
  debug "handling storage requested", requestId = $item.requestId,
    slot = item.slotIndex

  let agent = newSalesAgent(
    sales.context,
    item.requestId,
    item.slotIndex.u256,
    none StorageRequest
  )

  agent.context.onCleanUp = proc {.async.} =
    await sales.cleanUp(agent, item.doneProcessing)

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
      let slotQueue = context.slotQueue
      let items = SlotQueueItem.init(requestId, ask, expiry)
      if err =? slotQueue.push(items).errorOption:
        raise err
    except NoMatchingAvailabilityError:
      info "slot in queue had no matching availabilities, ignoring"
    except SlotsOutOfRangeError:
      warn "Too many slots, cannot add to queue", slots = ask.slots
    except CatchableError as e:
      warn "Error adding request to SlotQueue", error = e.msg
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
      agent.onFulfilled(requestId)

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
    queue.delete(requestId, slotIndex.truncate(uint16))

    for agent in sales.agents:
      agent.onSlotFilled(requestId, slotIndex)

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
      # first attempt to populate request using existing slot metadata in queue
      without var found =? SlotQueueItem.init(queue,
                                          requestId,
                                          slotIndex.truncate(uint16)):
        # if there's no existing slot for that request, retrieve the request
        # from the contract. This requires the subscription callback to be
        # async, which has been avoided on many occasions, so we are using
        # `waitFor`.
        without request =? waitFor market.getRequest(requestId):
          error "unknown request in contract"
          return

        found = SlotQueueItem.init(request, slotIndex.truncate(uint16))

      if err =? queue.push(found).errorOption:
        error "Error adding slot index to slot queue", error = err.msg

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
    proc(item: SlotQueueItem) {.async.} =
      sales.handleRequest(item)
  asyncSpawn slotQueue.start()

proc subscribe(sales: Sales) {.async.} =
  await sales.subscribeRequested()
  await sales.subscribeFulfilled()
  await sales.subscribeFailure()
  await sales.subscribeSlotFilled()
  await sales.subscribeSlotFreed()
  await sales.subscribeCancellation()

proc unsubscribe(sales: Sales) {.async.} =
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
  await sales.context.slotQueue.stop()
  await sales.unsubscribe()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]
  sales.stopping = false
