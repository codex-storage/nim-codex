import pkg/asynctest
import pkg/chronos
import pkg/codex/sales
import ./helpers/mockmarket
import ./helpers/mockclock
import ./examples

suite "Sales":

  let availability = Availability.init(
    size=100.u256,
    duration=60.u256,
    minPrice=42.u256
  )
  var request = StorageRequest(
    ask: StorageAsk(
      duration: 60.u256,
      size: 100.u256,
      maxPrice:42.u256
    ),
    content: StorageContent(
      cid: "some cid"
    )
  )
  let proof = seq[byte].example

  var sales: Sales
  var market: MockMarket
  var clock: MockClock

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    sales = Sales.new(market, clock)
    sales.retrieve = proc(_: string) {.async.} = discard
    sales.prove = proc(_: string): Future[seq[byte]] {.async.} = return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256

  teardown:
    await sales.stop()

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

  test "makes storage unavailable when matching request comes in":
    sales.add(availability)
    discard await market.requestStorage(request)
    check sales.available.len == 0

  test "ignores request when no matching storage is available":
    sales.add(availability)
    var tooBig = request
    tooBig.ask.size = request.ask.size + 1
    discard await market.requestStorage(tooBig)
    check sales.available == @[availability]

  test "retrieves data":
    var retrievingCid: string
    sales.retrieve = proc(cid: string) {.async.} = retrievingCid = cid
    sales.add(availability)
    discard await market.requestStorage(request)
    check retrievingCid == request.content.cid

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.retrieve = proc(cid: string) {.async.} = raise error
    sales.add(availability)
    discard await market.requestStorage(request)
    check sales.available == @[availability]

  test "generates proof of storage":
    var provingCid: string
    sales.prove = proc(cid: string): Future[seq[byte]] {.async.} = provingCid = cid
    sales.add(availability)
    discard await market.requestStorage(request)
    check provingCid == request.content.cid

  test "fulfills request":
    sales.add(availability)
    discard await market.requestStorage(request)
    check market.fulfilled.len == 1
    check market.fulfilled[0].requestId == request.id
    check market.fulfilled[0].proof == proof
    check market.fulfilled[0].host == await market.getSigner()

  test "calls onSale when request is fulfilled":
    var soldAvailability: Availability
    var soldRequest: StorageRequest
    sales.onSale = proc(availability: Availability, request: StorageRequest) =
      soldAvailability = availability
      soldRequest = request
    sales.add(availability)
    discard await market.requestStorage(request)
    check soldAvailability == availability
    check soldRequest == request

  test "makes storage available again when other host fulfills request":
    let otherHost = Address.example
    sales.retrieve = proc(_: string) {.async.} = await sleepAsync(1.hours)
    sales.add(availability)
    discard await market.requestStorage(request)
    market.fulfillRequest(request.id, proof, otherHost)
    check sales.available == @[availability]

  test "makes storage available again when request expires":
    sales.retrieve = proc(_: string) {.async.} = await sleepAsync(1.hours)
    sales.add(availability)
    discard await market.requestStorage(request)
    clock.set(request.expiry.truncate(int64))
    await sleepAsync(2.seconds)
    check sales.available == @[availability]
