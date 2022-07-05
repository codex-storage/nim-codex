import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import pkg/chronicles
import ./market
import ./clock

export stint

const DefaultOfferExpiryInterval = (10 * 60).u256

type
  Sales* = ref object
    market: Market
    clock: Clock
    subscription: ?Subscription
    available*: seq[Availability]
    offerExpiryInterval*: UInt256
    retrieve: ?Retrieve
    prove: ?Prove
    onSale: ?OnSale
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  Negotiation = ref object
    sales: Sales
    requestId: array[32, byte]
    ask: StorageAsk
    availability: Availability
    request: ?StorageRequest
    offer: ?StorageOffer
    subscription: ?Subscription
    running: ?Future[void]
    waiting: ?Future[void]
    finished: bool
  Retrieve = proc(cid: string): Future[void] {.gcsafe, upraises: [].}
  Prove = proc(cid: string): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnSale = proc(availability: Availability, request: StorageRequest) {.gcsafe, upraises: [].}

func new*(_: type Sales, market: Market, clock: Clock): Sales =
  Sales(
    market: market,
    clock: clock,
    offerExpiryInterval: DefaultOfferExpiryInterval
  )

proc init*(_: type Availability,
          size: UInt256,
          duration: UInt256,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

proc `retrieve=`*(sales: Sales, retrieve: Retrieve) =
  sales.retrieve = some retrieve

proc `prove=`*(sales: Sales, prove: Prove) =
  sales.prove = some prove

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.onSale = some callback

func add*(sales: Sales, availability: Availability) =
  sales.available.add(availability)

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)

func findAvailability(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.size <= availability.size and
       ask.duration <= availability.duration and
       ask.maxPrice >= availability.minPrice:
      return some availability

proc finish(negotiation: Negotiation, success: bool) =
  if negotiation.finished:
    return

  negotiation.finished = true

  if subscription =? negotiation.subscription:
    asyncSpawn subscription.unsubscribe()

  if running =? negotiation.running:
    running.cancel()

  if waiting =? negotiation.waiting:
    waiting.cancel()

  if success and request =? negotiation.request:
    if onSale =? negotiation.sales.onSale:
      onSale(negotiation.availability, request)
  else:
    negotiation.sales.add(negotiation.availability)

proc onFulfill(negotiation: Negotiation, requestId: array[32, byte]) {.async.} =
  try:
    let market = negotiation.sales.market
    let host = await market.getHost(requestId)
    let me = await market.getSigner()
    negotiation.finish(success = (host == me.some))
  except CatchableError:
    negotiation.finish(success = false)

proc subscribeFulfill(negotiation: Negotiation) {.async.} =
  proc onFulfill(requestId: array[32, byte]) {.gcsafe, upraises:[].} =
    asyncSpawn negotiation.onFulfill(requestId)
  let market = negotiation.sales.market
  let subscription = await market.subscribeFulfillment(negotiation.requestId, onFulfill)
  negotiation.subscription = some subscription

proc waitForExpiry(negotiation: Negotiation) {.async.} =
  without offer =? negotiation.offer:
    return
  await negotiation.sales.clock.waitUntil(offer.expiry.truncate(int64))
  negotiation.finish(success = false)

proc start(negotiation: Negotiation) {.async.} =
  try:
    let sales = negotiation.sales
    let market = sales.market
    let availability = negotiation.availability

    without retrieve =? sales.retrieve:
      raiseAssert "retrieve proc not set"

    without prove =? sales.prove:
      raiseAssert "prove proc not set"

    sales.remove(availability)

    await negotiation.subscribeFulfill()

    negotiation.request = await market.getRequest(negotiation.requestId)
    without request =? negotiation.request:
      negotiation.finish(success = false)
      return

    await retrieve(request.content.cid)
    let proof = await prove(request.content.cid)
    await market.fulfillRequest(request.id, proof)

    negotiation.waiting = some negotiation.waitForExpiry()
  except CancelledError:
    raise
  except CatchableError as e:
    error "Negotiation failed", msg = e.msg
    negotiation.finish(success = false)

proc handleRequest(sales: Sales, requestId: array[32, byte], ask: StorageAsk) =
  without availability =? sales.findAvailability(ask):
    return

  let negotiation = Negotiation(
    sales: sales,
    requestId: requestId,
    ask: ask,
    availability: availability
  )

  negotiation.running = some negotiation.start()

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: array[32, byte], ask: StorageAsk) {.gcsafe, upraises:[].} =
    sales.handleRequest(requestId, ask)

  try:
    sales.subscription = some await sales.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg
