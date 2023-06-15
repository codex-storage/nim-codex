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
import ./sales/requestqueue
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
    subscription*: ?market.Subscription
    agents*: seq[SalesAgent]

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
      requestQueue: RequestQueue.new()
    ),
  )

proc handleRequest(sales: Sales, rqi: RequestQueueItem) =
  debug "handling storage requested", requestId = $rqi.requestId,
    slots = rqi.ask.slots, slotSize = rqi.ask.slotSize,
    duration = rqi.ask.duration, reward = rqi.ask.reward,
    maxSlotLoss = rqi.ask.maxSlotLoss, expiry = rqi.expiry

  let agent = newSalesAgent(
    sales.context,
    rqi.requestId,
    none UInt256,
    none StorageRequest
  )
  agent.context.onIgnored = proc {.gcsafe, upraises:[].} =
                              sales.agents.keepItIf(it != agent)
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
      some slot.slotIndex,
      some slot.request)
    agent.start(SaleUnknown())
    sales.agents.add agent

proc subscribeRequestEvents(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  let context = sales.context
  let market = context.market

  proc onRequestEvent(requestId: RequestId,
                 ask: StorageAsk,
                 expiry: UInt256) {.gcsafe, upraises:[].} =
    try:
      let reservations = context.reservations
      let requestQueue = context.requestQueue
      # Match availability before pushing. If availabilities weren't matched,
      # every request in the network would get added to the request queue.
      # However, matching availabilities requires the subscription callback to
      # be async, which has been avoided on many occasions, so we are using
      # `waitFor`.
      if availability =? waitFor reservations.find(ask.slotSize,
                                                   ask.duration,
                                                   ask.pricePerSlot,
                                                   ask.collateral,
                                                   used = false):
        let rqi = RequestQueueItem.init(requestId, ask, expiry)
        requestQueue.pushOrUpdate(rqi)
    except CatchableError as e:
      error "Error pushing request to RequestQueue", error = e.msg
      discard

  try:
    sales.subscription =
      some await market.subscribeRequests(onRequestEvent)
  except CatchableError as e:
    error "Unable to subscribe to storage request events", msg = e.msg

proc startRequestQueue(sales: Sales) {.async.} =
  let requestQueue = sales.context.requestQueue
  requestQueue.onProcessRequest = proc(rqi: RequestQueueItem) =
                                    sales.handleRequest(rqi)
  asyncSpawn requestQueue.start()

proc start*(sales: Sales) {.async.} =
  await sales.startRequestQueue()
  await sales.subscribeRequestEvents()

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg

  sales.context.requestQueue.stop()

  for agent in sales.agents:
    await agent.stop()
