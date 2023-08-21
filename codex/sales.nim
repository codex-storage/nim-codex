import std/sequtils
import std/sugar
import std/tables
import pkg/questionable
import pkg/stint
import pkg/chronicles
import pkg/datastore
import ./market
import ./clock
import ./stores
import ./contracts/requests
import ./contracts/marketplace
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/slotqueue
import ./sales/states/preparing
import ./sales/states/unknown
import ./utils/then
import ./utils/trackedfutures

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
  topics = "sales marketplace"

type
  Sales* = ref object
    context*: SalesContext
    agents*: seq[SalesAgent]
    running: bool
    subscriptions: seq[market.Subscription]
    trackedFutures: TrackedFutures

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc `onProve=`*(sales: Sales, callback: OnProve) =
  sales.context.onProve = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

proc onProve*(sales: Sales): ?OnProve = sales.context.onProve

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          repo: RepoStore): Sales =
  Sales.new(market, clock, repo, 0)

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          repo: RepoStore,
          simulateProofFailures: int): Sales =

  let reservations = Reservations.new(repo)
  Sales(
    context: SalesContext(
      market: market,
      clock: clock,
      reservations: reservations,
      slotQueue: SlotQueue.new(),
      simulateProofFailures: simulateProofFailures
    ),
    trackedFutures: TrackedFutures.new(),
    subscriptions: @[]
  )

proc remove(sales: Sales, agent: SalesAgent) {.async.} =
  await agent.stop()
  if sales.running:
    sales.agents.keepItIf(it != agent)

proc filled(sales: Sales,
             processing: Future[void]) =
  if not processing.isNil and not processing.finished():
    processing.complete()

proc processSlot(sales: Sales, item: SlotQueueItem, done: Future[void]) =
  debug "processing slot from queue", requestId = $item.requestId,
    slot = item.slotIndex

  let agent = newSalesAgent(
    sales.context,
    item.requestId,
    item.slotIndex.u256,
    none StorageRequest
  )

  agent.context.onCleanUp = proc {.async.} =
    await sales.remove(agent)

  agent.context.onFilled = some proc(request: StorageRequest, slotIndex: UInt256) =
      sales.filled(done)

  agent.start(SalePreparing())
  sales.agents.add agent

proc mySlots*(sales: Sales): Future[seq[Slot]] {.async.} =
  let market = sales.context.market
  let slotIds = await market.mySlots()
  var slots: seq[Slot] = @[]

  info "Loading active slots", slotsCount = len(slots)
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

proc onAvailabilityAdded(sales: Sales, availability: Availability) {.async.} =
  ## Query last 256 blocks for new requests, adding them to the queue. `push`
  ## checks for availability before adding to the queue. If processed, the
  ## sales agent will check if the slot is free.
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  logScope:
    topics = "marketplace sales onReservationAdded callback"

  trace "reservation added, querying past storage requests to add to queue"

  try:
    let events = await market.queryPastStorageRequests(256)

    if events.len == 0:
      trace "no storage request events found in recent past"
      return

    let requests = events.map(event =>
      SlotQueueItem.init(event.requestId, event.ask, event.expiry)
    )

    trace "found past storage requested events to add to queue",
      events = events.len

    for slots in requests:
      for slot in slots:
        if err =? queue.push(slot).errorOption:
          # continue on error
          if err of QueueNotRunningError:
            warn "cannot push items to queue, queue is not running"
          elif err of NoMatchingAvailabilityError:
            info "slot in queue had no matching availabilities, ignoring"
          elif err of SlotsOutOfRangeError:
            warn "Too many slots, cannot add to queue"
          elif err of SlotQueueItemExistsError:
            trace "item already exists, ignoring"
            discard
          else: raise err

  except CatchableError as e:
    warn "Error adding request to SlotQueue", error = e.msg
    discard

proc onStorageRequested(sales: Sales,
                        requestId: RequestId,
                        ask: StorageAsk,
                        expiry: UInt256) =

  logScope:
    topics = " marketplace sales onStorageRequested"
    requestId
    slots = ask.slots
    expiry

  let slotQueue = sales.context.slotQueue

  trace "storage requested, adding slots to queue"

  without items =? SlotQueueItem.init(requestId, ask, expiry).catch, err:
    if err of SlotsOutOfRangeError:
      warn "Too many slots, cannot add to queue"
    else:
      warn "Failed to create slot queue items from request", error = err.msg
    return

  for item in items:
    # continue on failure
    if err =? slotQueue.push(item).errorOption:
      if err of NoMatchingAvailabilityError:
        info "slot in queue had no matching availabilities, ignoring"
      elif err of SlotQueueItemExistsError:
        error "Failed to push item to queue becaue it already exists"
      elif err of QueueNotRunningError:
        warn "Failed to push item to queue becaue queue is not running"
      else:
        warn "Error adding request to SlotQueue", error = err.msg

proc onSlotFreed(sales: Sales,
                 requestId: RequestId,
                 slotIndex: UInt256) =

  logScope:
    topics = "marketplace sales onSlotFreed"
    requestId
    slotIndex

  trace "slot freed, adding to queue"

  proc addSlotToQueue() {.async.} =
    let context = sales.context
    let market = context.market
    let queue = context.slotQueue

    # first attempt to populate request using existing slot metadata in queue
    without var found =? queue.populateItem(requestId,
                                            slotIndex.truncate(uint16)):
      trace "no existing request metadata, getting request info from contract"
      # if there's no existing slot for that request, retrieve the request
      # from the contract.
      without request =? await market.getRequest(requestId):
        error "unknown request in contract"
        return

      found = SlotQueueItem.init(request, slotIndex.truncate(uint16))

    if err =? queue.push(found).errorOption:
      raise err

  addSlotToQueue()
    .track(sales)
    .catch(proc(err: ref CatchableError) =
      if err of NoMatchingAvailabilityError:
        info "slot in queue had no matching availabilities, ignoring"
      elif err of SlotQueueItemExistsError:
        error "Failed to push item to queue becaue it already exists"
      elif err of QueueNotRunningError:
        warn "Failed to push item to queue becaue queue is not running"
      else:
        warn "Error adding request to SlotQueue", error = err.msg
    )

proc subscribeRequested(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market

  proc onStorageRequested(requestId: RequestId,
                          ask: StorageAsk,
                          expiry: UInt256) =
    sales.onStorageRequested(requestId, ask, expiry)

  try:
    let sub = await market.subscribeRequests(onStorageRequested)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to storage request events", msg = e.msg

proc subscribeCancellation(sales: Sales) {.async.} =
  let context = sales.context
  let market = context.market
  let queue = context.slotQueue

  proc onCancelled(requestId: RequestId) =
    trace "request cancelled, removing all request slots from queue"
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
    trace "request fulfilled, removing all request slots from queue"
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
    trace "request failed, removing all request slots from queue"
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
    trace "slot filled, removing from slot queue", requestId, slotIndex
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

  proc onSlotFreed(requestId: RequestId, slotIndex: UInt256) =
    sales.onSlotFreed(requestId, slotIndex)

  try:
    let sub = await market.subscribeSlotFreed(onSlotFreed)
    sales.subscriptions.add(sub)
  except CatchableError as e:
    error "Unable to subscribe to slot freed events", msg = e.msg

proc startSlotQueue(sales: Sales) {.async.} =
  let slotQueue = sales.context.slotQueue
  let reservations = sales.context.reservations

  slotQueue.onProcessSlot =
    proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      sales.processSlot(item, done)

  asyncSpawn slotQueue.start()

  proc onAvailabilityAdded(availability: Availability) {.async.} =
    await sales.onAvailabilityAdded(availability)

  reservations.onAdded = onAvailabilityAdded
  reservations.onMarkUnused = onAvailabilityAdded


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
  await sales.load()
  await sales.startSlotQueue()
  await sales.subscribe()

proc stop*(sales: Sales) {.async.} =
  trace "stopping sales"
  sales.running = false
  await sales.context.slotQueue.stop()
  await sales.unsubscribe()
  await sales.trackedFutures.cancelTracked()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]
