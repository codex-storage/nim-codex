import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/chronicles
import pkg/datastore
import ./rng
import ./market
import ./clock
import ./proving
import ./stores
import ./contracts/requests
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/requestqueue
import ./sales/states/downloading
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
    requestQueue: RequestQueue

proc handleRequest(sales: Sales, rqi: RequestQueueItem)

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

  let sales = Sales(context: SalesContext(
    market: market,
    clock: clock,
    proving: proving,
    reservations: Reservations.new(repo)
  ))

  proc handleRequest(rqi: RequestQueueItem) =
    sales.handleRequest(rqi)

  sales.requestQueue = RequestQueue.new(handleRequest)

  return sales

proc randomSlotIndex(numSlots: uint64): UInt256 =
  let rng = Rng.instance
  let slotIndex = rng.rand(numSlots - 1)
  return slotIndex.u256

proc handleRequest(sales: Sales, rqi: RequestQueueItem) =

  debug "handling storage requested", requestId = rqi.requestId,
    collateral = rqi.collateral, expiry = rqi.expiry, totalChunks = rqi.expiry,
    slots = rqi.slot

  # TODO: check if random slot is actually available (not already filled)
  let slotIndex = randomSlotIndex(ask.slots)
  let agent = newSalesAgent(
    sales.context,
    requestId,
    slotIndex,
    none StorageRequest
  )
  agent.context.onIgnored = proc {.gcsafe, upraises:[].} =
                              sales.agents.keepItIf(it != agent)
  agent.start(SaleDownloading())
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
    agent.start(SaleUnknown())
    sales.agents.add agent

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId,
                 collateral, expiry: UInt256,
                 totalChunks, slots: uint64) {.gcsafe, upraises:[].} =
    let rqi = RequestQueueItem.init(requestId, collateral, expiry, totalChunks, slots)
    sales.requestQueue.pushOrUpdate(rqi)

  try:
    sales.subscription = some await sales.context.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

  asyncSpawn sales.requestQueue.start()

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg

  sales.requestQueue.stop()

  for agent in sales.agents:
    await agent.stop()
