import std/times
import pkg/asynctest
import pkg/chronos
import pkg/dagger/sales
import ./helpers/mockmarket
import ./examples

suite "Sales":

  var sales: Sales
  var market: MockMarket

  setup:
    market = MockMarket.new()
    sales = Sales.new(market)

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
    let availability = Availability.example
    sales.add(availability)
    sales.remove(availability)
    check sales.available.len == 0

  test "generates unique ids for storage availability":
    let availability1 = Availability.init(size=1, duration=2, minPrice=3.u256)
    let availability2 = Availability.init(size=1, duration=2, minPrice=3.u256)
    check availability1.id != availability2.id

  test "offers available storage when matching request comes in":
    let availability = Availability.init(size=100, duration=60, minPrice=42.u256)
    sales.add(availability)
    sales.start()
    let request = StorageRequest(duration:60.u256, size:100.u256, maxPrice:42.u256)
    await market.requestStorage(request)
    check market.offered.len == 1
    check market.offered[0].price == 42.u256
    sales.stop()

  test "ignores request when no matching storage is available":
    let availability = Availability.init(size=99, duration=60, minPrice=42.u256)
    sales.add(availability)
    sales.start()
    let request = StorageRequest(duration:60.u256, size:100.u256, maxPrice:42.u256)
    await market.requestStorage(request)
    check market.offered.len == 0
    sales.stop()

  test "makes storage unavailable when offer is submitted":
    let availability = Availability.init(size=100, duration=60, minPrice=42.u256)
    sales.add(availability)
    sales.start()
    let request = StorageRequest(duration:60.u256, size:100.u256, maxPrice:42.u256)
    await market.requestStorage(request)
    check sales.available.len == 0
    sales.stop()

  test "sets expiry time of offer":
    let availability = Availability.init(size=100, duration=60, minPrice=42.u256)
    sales.add(availability)
    sales.start()
    let request = StorageRequest(duration:60.u256, size:100.u256, maxPrice:42.u256)
    let now = getTime().toUnix().u256
    await market.requestStorage(request)
    check market.offered[0].expiry == now + sales.offerExpiryInterval
    sales.stop()
