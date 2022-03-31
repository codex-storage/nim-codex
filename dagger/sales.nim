import std/times
import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import ./market

export stint

const DefaultOfferExpiryInterval = (10 * 60).u256

type
  Sales* = ref object
    market: Market
    subscription: ?Subscription
    available*: seq[Availability]
    offerExpiryInterval*: UInt256
    onSale*: OnSale
  Availability* = object
    id*: array[32, byte]
    size*: uint64
    duration*: uint64
    minPrice*: UInt256
  OnSale = proc(offer: StorageOffer) {.gcsafe, upraises: [].}

func new*(_: type Sales, market: Market): Sales =
  Sales(market: market, offerExpiryInterval: DefaultOfferExpiryInterval)

proc init*(_: type Availability,
          size: uint64,
          duration: uint64,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

func add*(sales: Sales, availability: Availability) =
  sales.available.add(availability)

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)

func findAvailability(sales: Sales, request: StorageRequest): ?Availability =
  for availability in sales.available:
    if request.size <= availability.size.u256 and
       request.duration <= availability.duration.u256 and
       request.maxPrice >= availability.minPrice:
      return some availability

proc createOffer(sales: Sales,
                 request: StorageRequest,
                 availability: Availability): StorageOffer =
  StorageOffer(
    requestId: request.id,
    price: request.maxPrice,
    expiry: getTime().toUnix().u256 + sales.offerExpiryInterval
  )

proc handleRequest(sales: Sales, request: StorageRequest) {.async.} =
  without availability =? sales.findAvailability(request):
    return

  sales.remove(availability)

  var offer = sales.createOffer(request, availability)
  offer = await sales.market.offerStorage(offer)

  var subscription: ?Subscription
  proc onSelect(offerId: array[32, byte]) {.gcsafe, upraises:[].} =
    if subscription =? subscription:
      asyncSpawn subscription.unsubscribe()
    if offer.id == offerId:
      sales.onSale(offer)
  subscription = some await sales.market.subscribeSelection(request.id, onSelect)

proc start*(sales: Sales) =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(request: StorageRequest) {.gcsafe, upraises:[].} =
    asyncSpawn sales.handleRequest(request)

  proc subscribe {.async.} =
    sales.subscription = some await sales.market.subscribeRequests(onRequest)

  asyncSpawn subscribe()

proc stop*(sales: Sales) =
  if subscription =? sales.subscription:
    asyncSpawn subscription.unsubscribe()
    sales.subscription = Subscription.none
