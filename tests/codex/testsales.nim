import std/sets
import std/times
import pkg/asynctest
import pkg/chronos
import pkg/codex/contracts/requests
import pkg/codex/sales
import ./helpers/mockmarket
import ./helpers/mockclock
import ./helpers/eventually
import ./examples

suite "Sales":

  let availability = Availability.init(
    size=100.u256,
    duration=60.u256,
    minPrice=600.u256
  )
  var request = StorageRequest(
    ask: StorageAsk(
      slots: 4,
      slotSize: 100.u256,
      duration: 60.u256,
      reward: 10.u256,
    ),
    content: StorageContent(
      cid: "some cid"
    ),
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256
  )
  let proof = exampleProof()

  var sales: Sales
  var market: MockMarket
  var clock: MockClock
  var proving: Proving

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    proving = Proving.new()
    sales = Sales.new(market, clock, proving)
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      discard
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      return proof
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
    await market.requestStorage(request)
    check sales.available.len == 0

  test "ignores request when no matching storage is available":
    sales.add(availability)
    var tooBig = request
    tooBig.ask.slotSize = request.ask.slotSize + 1
    await market.requestStorage(tooBig)
    check sales.available == @[availability]

  test "ignores request when reward is too low":
    sales.add(availability)
    var tooCheap = request
    tooCheap.ask.reward = request.ask.reward - 1
    await market.requestStorage(tooCheap)
    check sales.available == @[availability]

  test "retrieves and stores data locally":
    var storingRequest: StorageRequest
    var storingSlot: UInt256
    var storingAvailability: Availability
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      storingRequest = request
      storingSlot = slot
      check availability.isSome
      storingAvailability = !availability
    sales.add(availability)
    await market.requestStorage(request)
    check storingRequest == request
    check storingSlot < request.ask.slots.u256
    check storingAvailability == availability

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      raise error
    sales.add(availability)
    await market.requestStorage(request)
    check sales.available == @[availability]

  test "generates proof of storage":
    var provingRequest: StorageRequest
    var provingSlot: UInt256
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      provingRequest = request
      provingSlot = slot
    sales.add(availability)
    await market.requestStorage(request)
    check provingRequest == request
    check provingSlot < request.ask.slots.u256

  test "fills a slot":
    sales.add(availability)
    await market.requestStorage(request)
    check market.filled.len == 1
    check market.filled[0].requestId == request.id
    check market.filled[0].slotIndex < request.ask.slots.u256
    check market.filled[0].proof == proof
    check market.filled[0].host == await market.getSigner()

  test "calls onSale when slot is filled":
    var soldAvailability: Availability
    var soldRequest: StorageRequest
    var soldSlotIndex: UInt256
    sales.onSale = proc(availability: ?Availability,
                        request: StorageRequest,
                        slotIndex: UInt256) =
      if a =? availability:
        soldAvailability = a
      soldRequest = request
      soldSlotIndex = slotIndex
    sales.add(availability)
    await market.requestStorage(request)
    check soldAvailability == availability
    check soldRequest == request
    check soldSlotIndex < request.ask.slots.u256

  test "calls onClear when storage becomes available again":
    # fail the proof intentionally to trigger `agent.finish(success=false)`,
    # which then calls the onClear callback
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      raise newException(IOError, "proof failed")
    var clearedAvailability: Availability
    var clearedRequest: StorageRequest
    var clearedSlotIndex: UInt256
    sales.onClear = proc(availability: ?Availability,
                         request: StorageRequest,
                         slotIndex: UInt256) =
      if a =? availability:
        clearedAvailability = a
      clearedRequest = request
      clearedSlotIndex = slotIndex
    sales.add(availability)
    await market.requestStorage(request)
    check clearedAvailability == availability
    check clearedRequest == request
    check clearedSlotIndex < request.ask.slots.u256

  test "makes storage available again when other host fills the slot":
    let otherHost = Address.example
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.hours(1))
    sales.add(availability)
    await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    check sales.available == @[availability]

  test "makes storage available again when request expires":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.hours(1))
    sales.add(availability)
    await market.requestStorage(request)
    clock.set(request.expiry.truncate(int64))
    check eventually (sales.available == @[availability])

  test "adds proving for slot when slot is filled":
    var soldSlotIndex: UInt256
    sales.onSale = proc(availability: ?Availability,
                        request: StorageRequest,
                        slotIndex: UInt256) =
      soldSlotIndex = slotIndex
    check proving.slots.len == 0
    sales.add(availability)
    await market.requestStorage(request)
    check proving.slots.len == 1
    check proving.slots.contains(request.slotId(soldSlotIndex))
