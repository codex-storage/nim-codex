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
    offer: ?StorageOffer
    subscription: ?Subscription
    waiting: ?Future[void]
    finished: bool
  OnSale = proc(offer: StorageOffer) {.gcsafe, upraises: [].}

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

proc createOffer(negotiation: Negotiation): StorageOffer =
  let sales = negotiation.sales
  StorageOffer(
    requestId: negotiation.requestId,
    price: negotiation.ask.maxPrice,
    expiry: sales.clock.now().u256 + sales.offerExpiryInterval
  )

proc sendOffer(negotiation: Negotiation) {.async.} =
  let offer = negotiation.createOffer()
  negotiation.offer = some await negotiation.sales.market.offerStorage(offer)

proc finish(negotiation: Negotiation, success: bool) =
  if negotiation.finished:
    return

  negotiation.finished = true

  if subscription =? negotiation.subscription:
    asyncSpawn subscription.unsubscribe()

  if waiting =? negotiation.waiting:
    waiting.cancel()

  if success and offer =? negotiation.offer:
    if onSale =? negotiation.sales.onSale:
      onSale(offer)
  else:
    negotiation.sales.add(negotiation.availability)

proc onSelect(negotiation: Negotiation, offerId: array[32, byte]) =
  if offer =? negotiation.offer and offer.id == offerId:
    negotiation.finish(success = true)
  else:
    negotiation.finish(success = false)

proc subscribeSelect(negotiation: Negotiation) {.async.} =
  without offer =? negotiation.offer:
    return
  proc onSelect(offerId: array[32, byte]) {.gcsafe, upraises:[].} =
    negotiation.onSelect(offerId)
  let market = negotiation.sales.market
  let subscription = await market.subscribeSelection(offer.requestId, onSelect)
  negotiation.subscription = some subscription

proc waitForExpiry(negotiation: Negotiation) {.async.} =
  without offer =? negotiation.offer:
    return
  await negotiation.sales.market.waitUntil(offer.expiry)
  negotiation.finish(success = false)

proc start(negotiation: Negotiation) {.async.} =
  try:
    let sales = negotiation.sales
    let availability = negotiation.availability
    sales.remove(availability)
    await negotiation.sendOffer()
    await negotiation.subscribeSelect()
    negotiation.waiting = some negotiation.waitForExpiry()
  except CatchableError as e:
    error "Negotiation failed", msg = e.msg

proc handleRequest(sales: Sales, requestId: array[32, byte], ask: StorageAsk) =
  without availability =? sales.findAvailability(ask):
    return

  let negotiation = Negotiation(
    sales: sales,
    requestId: requestId,
    ask: ask,
    availability: availability
  )

  asyncSpawn negotiation.start()

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
