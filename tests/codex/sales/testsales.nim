import std/sets
import std/sequtils
import std/sugar
import std/times
import pkg/asynctest
import pkg/chronos
import pkg/codex/sales
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples

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
    check eventually sales.available.len == 0

  test "ignores request when no matching storage is available":
    sales.add(availability)
    var tooBig = request
    tooBig.ask.slotSize = request.ask.slotSize + 1
    await market.requestStorage(tooBig)
    await sleepAsync(1.millis)
    check eventually sales.available == @[availability]

  test "ignores request when reward is too low":
    sales.add(availability)
    var tooCheap = request
    tooCheap.ask.reward = request.ask.reward - 1
    await market.requestStorage(tooCheap)
    await sleepAsync(1.millis)
    check eventually sales.available == @[availability]

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
    check eventually storingRequest == request
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
    await sleepAsync(1.millis)
    check eventually sales.available == @[availability]

  test "generates proof of storage":
    var provingRequest: StorageRequest
    var provingSlot: UInt256
    sales.onProve = proc(request: StorageRequest,
                         slot: UInt256): Future[seq[byte]] {.async.} =
      provingRequest = request
      provingSlot = slot
    sales.add(availability)
    await market.requestStorage(request)
    check eventually provingRequest == request
    check provingSlot < request.ask.slots.u256

  test "fills a slot":
    sales.add(availability)
    await market.requestStorage(request)
    check eventually market.filled.len == 1
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
    check eventually soldAvailability == availability
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
    check eventually clearedAvailability == availability
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
    await sleepAsync(1.millis)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    await sleepAsync(chronos.seconds(2))
    check sales.available == @[availability]

  test "makes storage available again when request expires":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.hours(1))
    sales.add(availability)
    await market.requestStorage(request)
    await sleepAsync(1.millis)
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
    check eventually proving.slots.len == 1
    check proving.slots.contains(request.slotId(soldSlotIndex))

  test "loads active slots from market":
    let me = await market.getSigner()

    request.ask.slots = 2
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New

    proc fillSlot(slotIdx: UInt256 = 0.u256) {.async.} =
      let address = await market.getSigner()
      let slot = MockSlot(requestId: request.id,
                          slotIndex: slotIdx,
                          proof: proof,
                          host: address)
      market.filled.add slot
      market.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

    let slot0 = MockSlot(requestId: request.id,
                     slotIndex: 0.u256,
                     proof: proof,
                     host: me)
    await fillSlot(slot0.slotIndex)

    let slot1 = MockSlot(requestId: request.id,
                     slotIndex: 1.u256,
                     proof: proof,
                     host: me)
    await fillSlot(slot1.slotIndex)
    market.activeSlots[me] = @[request.slotId(0.u256), request.slotId(1.u256)]
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]

    await sales.load()
    let expected = SalesAgent(sales: sales,
                               requestId: request.id,
                               availability: none Availability,
                               request: some request)
    # because sales.load() calls agent.start, we won't know the slotIndex
    # randomly selected for the agent, and we also won't know the value of
    # `failed`/`fulfilled`/`cancelled` futures, so we need to compare
    # the properties we know
    # TODO: when calling sales.load(), slot index should be restored and not
    # randomly re-assigned, so this may no longer be needed
    proc `==` (agent0, agent1: SalesAgent): bool =
      return agent0.sales == agent1.sales and
             agent0.requestId == agent1.requestId and
             agent0.availability == agent1.availability and
             agent0.request == agent1.request

    check eventually sales.agents.len == 2
    check sales.agents.all(agent => agent == expected)
