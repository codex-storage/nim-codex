import std/times
import pkg/asynctest
import pkg/chronos
import pkg/dagger/sales
import ./helpers/mockmarket
import ./examples

suite "Sales":

  let availability = Availability.init(
    size=100.u256,
    duration=60.u256,
    minPrice=42.u256
  )
  let request = StorageRequest(ask: StorageAsk(
    duration: 60.u256,
    size: 100.u256,
    maxPrice:42.u256
  ))

  var sales: Sales
  var market: MockMarket

  setup:
    market = MockMarket.new()
    sales = Sales.new(market)
    sales.start()

  teardown:
    sales.stop()

  test "has no availability initially":
    check sales.available.len == 0

  test "can add available storage":
    let availability1 = Availability.example
    let availability2 = Availability.example
    sales.add(availability1)
    check sales.available.contains(availability1)
    sales.add(availability2)
    check sales.available.contains(availability1)
    check sales.available.contains(availability2)

  test "can remove available storage":
    sales.add(availability)
    sales.remove(availability)
    check sales.available.len == 0

  test "generates unique ids for storage availability":
    let availability1 = Availability.init(1.u256, 2.u256, 3.u256)
    let availability2 = Availability.init(1.u256, 2.u256, 3.u256)
    check availability1.id != availability2.id

  test "offers available storage when matching request comes in":
    sales.add(availability)
    discard await market.requestStorage(request)
    check market.offered.len == 1
    check market.offered[0].price == 42.u256

  test "ignores request when no matching storage is available":
    sales.add(availability)
    var tooBig = request
    tooBig.ask.size = request.ask.size + 1
    discard await market.requestStorage(tooBig)
    check market.offered.len == 0

  test "makes storage unavailable when offer is submitted":
    sales.add(availability)
    discard await market.requestStorage(request)
    check sales.available.len == 0

  test "sets expiry time of offer":
    sales.add(availability)
    let now = getTime().toUnix().u256
    discard await market.requestStorage(request)
    check market.offered[0].expiry == now + sales.offerExpiryInterval

  test "calls onSale when offer is selected":
    var sold: StorageOffer
    sales.onSale = proc(offer: StorageOffer) =
      sold = offer
    sales.add(availability)
    discard await market.requestStorage(request)
    let offer = market.offered[0]
    await market.selectOffer(offer.id)
    check sold == offer

  test "does not call onSale when a different offer is selected":
    var didSell: bool
    sales.onSale = proc(offer: StorageOffer) =
      didSell = true
    sales.add(availability)
    let request = await market.requestStorage(request)
    var otherOffer = StorageOffer(requestId: request.id, price: 1.u256)
    otherOffer = await market.offerStorage(otherOffer)
    await market.selectOffer(otherOffer.id)
    check not didSell

  test "makes storage available again when different offer is selected":
    sales.add(availability)
    let request = await market.requestStorage(request)
    var otherOffer = StorageOffer(requestId: request.id, price: 1.u256)
    otherOffer = await market.offerStorage(otherOffer)
    await market.selectOffer(otherOffer.id)
    check sales.available.contains(availability)

  test "makes storage available again when offer expires":
    sales.add(availability)
    discard await market.requestStorage(request)
    let offer = market.offered[0]
    market.advanceTimeTo(offer.expiry)
    await sleepAsync(chronos.seconds(1))
    check sales.available.contains(availability)
