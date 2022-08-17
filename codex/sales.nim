import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import pkg/chronicles
import ./rng
import ./market
import ./clock
import ./proving
import ./contracts/requests

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

type
  Sales* = ref object
    market: Market
    clock: Clock
    subscription: ?market.Subscription
    available*: seq[Availability]
    onStore: ?OnStore
    onProve: ?OnProve
    onClear: ?OnClear
    onSale: ?OnSale
    proving: Proving
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  SalesAgent = ref object
    sales: Sales
    requestId: RequestId
    ask: StorageAsk
    availability: Availability
    request: ?StorageRequest
    slotIndex: ?UInt256
    subscription: ?market.Subscription
    running: ?Future[void]
    waiting: ?Future[void]
    finished: bool
  OnStore = proc(request: StorageRequest,
                 slot: UInt256,
                 availability: Availability): Future[void] {.gcsafe, upraises: [].}
  OnProve = proc(request: StorageRequest,
                 slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear = proc(availability: Availability,
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale = proc(availability: Availability,
                request: StorageRequest,
                slotIndex: UInt256) {.gcsafe, upraises: [].}

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving): Sales =
  Sales(
    market: market,
    clock: clock,
    proving: proving
  )

proc init*(_: type Availability,
          size: UInt256,
          duration: UInt256,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.onStore = some onStore

proc `onProve=`*(sales: Sales, onProve: OnProve) =
  sales.onProve = some onProve

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.onSale = some callback

func add*(sales: Sales, availability: Availability) =
  sales.available.add(availability)

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)

func findAvailability(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.slotSize <= availability.size and
       ask.duration <= availability.duration and
       ask.pricePerSlot >= availability.minPrice:
      return some availability

proc finish(agent: SalesAgent, success: bool) =
  if agent.finished:
    return

  agent.finished = true

  if subscription =? agent.subscription:
    asyncSpawn subscription.unsubscribe()

  if running =? agent.running:
    running.cancel()

  if waiting =? agent.waiting:
    waiting.cancel()

  if success:
    if request =? agent.request and
       slotIndex =? agent.slotIndex:
      agent.sales.proving.add(request.slotId(slotIndex))

      if onSale =? agent.sales.onSale:
        onSale(agent.availability, request, slotIndex)
  else:
    if onClear =? agent.sales.onClear and
       request =? agent.request and
       slotIndex =? agent.slotIndex:
      onClear(agent.availability, request, slotIndex)
    agent.sales.add(agent.availability)

proc selectSlot(agent: SalesAgent)  =
  let rng = Rng.instance
  let slotIndex = rng.rand(agent.ask.slots - 1)
  agent.slotIndex = some slotIndex.u256

proc onSlotFilled(agent: SalesAgent,
                  requestId: RequestId,
                  slotIndex: UInt256) {.async.} =
  try:
    let market = agent.sales.market
    let host = await market.getHost(requestId, slotIndex)
    let me = await market.getSigner()
    agent.finish(success = (host == me.some))
  except CatchableError:
    agent.finish(success = false)

proc subscribeSlotFilled(agent: SalesAgent, slotIndex: UInt256) {.async.} =
  proc onSlotFilled(requestId: RequestId,
                    slotIndex: UInt256) {.gcsafe, upraises:[].} =
    asyncSpawn agent.onSlotFilled(requestId, slotIndex)
  let market = agent.sales.market
  let subscription = await market.subscribeSlotFilled(agent.requestId,
                                                      slotIndex,
                                                      onSlotFilled)
  agent.subscription = some subscription

proc waitForExpiry(agent: SalesAgent) {.async.} =
  without request =? agent.request:
    return
  await agent.sales.clock.waitUntil(request.expiry.truncate(int64))
  agent.finish(success = false)

proc start(agent: SalesAgent) {.async.} =
  try:
    let sales = agent.sales
    let market = sales.market
    let availability = agent.availability

    without onStore =? sales.onStore:
      raiseAssert "onStore callback not set"

    without onProve =? sales.onProve:
      raiseAssert "onProve callback not set"

    sales.remove(availability)

    agent.selectSlot()
    without slotIndex =? agent.slotIndex:
      raiseAssert "no slot selected"

    await agent.subscribeSlotFilled(slotIndex)

    agent.request = await market.getRequest(agent.requestId)
    without request =? agent.request:
      agent.finish(success = false)
      return

    agent.waiting = some agent.waitForExpiry()

    await onStore(request, slotIndex, availability)
    let proof = await onProve(request, slotIndex)
    await market.fillSlot(request.id, slotIndex, proof)
  except CancelledError:
    raise
  except CatchableError as e:
    error "SalesAgent failed", msg = e.msg
    agent.finish(success = false)

proc handleRequest(sales: Sales, requestId: RequestId, ask: StorageAsk) =
  without availability =? sales.findAvailability(ask):
    return

  let agent = SalesAgent(
    sales: sales,
    requestId: requestId,
    ask: ask,
    availability: availability
  )

  agent.running = some agent.start()

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].} =
    sales.handleRequest(requestId, ask)

  try:
    sales.subscription = some await sales.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg
