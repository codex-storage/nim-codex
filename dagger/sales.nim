import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import ./market

export stint

type
  Sales* = ref object
    market: Market
    available*: seq[Availability]
    subscription: ?Subscription

  Availability* = object
    id*: array[32, byte]
    size*: uint64
    duration*: uint64
    minPrice*: UInt256

func new*(_: type Sales, market: Market): Sales =
  Sales(market: market)

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

func createOffer(sales: Sales,
                 request: StorageRequest,
                 availability: Availability): StorageOffer =
  StorageOffer(
    requestId: request.id,
    price: request.maxPrice
  )

proc handleRequest(sales: Sales, request: StorageRequest) {.async.} =
  if availability =? sales.findAvailability(request):
    sales.remove(availability)
    let offer = sales.createOffer(request, availability)
    await sales.market.offerStorage(offer)

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
