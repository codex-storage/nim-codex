import std/sets
import std/sequtils
import std/sugar
import std/times
import pkg/asynctest
import pkg/chronos
import pkg/datastore
import pkg/questionable
import pkg/questionable/results
import pkg/codex/sales
import pkg/codex/sales/salesdata
import pkg/codex/sales/reservations
import pkg/codex/stores/repostore
import pkg/codex/proving
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples
import ./helpers

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
  var reservations: Reservations

  setup:
    market = MockMarket.new()
    clock = MockClock.new()
    proving = Proving.new()
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    let repo = RepoStore.new(repoDs, metaDs)
    sales = Sales.new(market, clock, proving, repo)
    reservations = sales.context.reservations
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      discard
    proving.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256

  teardown:
    await sales.stop()

  test "makes storage unavailable when matching request comes in":
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    await sleepAsync(1.millis)
    without availability =? await reservations.get(availability.id):
      fail()
    check availability.used

  test "ignores request when no matching storage is available":
    check isOk await reservations.reserve(availability)
    var tooBig = request
    tooBig.ask.slotSize = request.ask.slotSize + 1
    await market.requestStorage(tooBig)
    await sleepAsync(1.millis)
    without availability =? await reservations.get(availability.id):
      fail()
    check not availability.used

  test "ignores request when reward is too low":
    check isOk await reservations.reserve(availability)
    var tooCheap = request
    tooCheap.ask.reward = request.ask.reward - 1
    await market.requestStorage(tooCheap)
    await sleepAsync(1.millis)
    without availability =? await reservations.get(availability.id):
      fail()
    check not availability.used

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
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually storingRequest == request
    check storingSlot < request.ask.slots.u256
    check storingAvailability == availability

  test "handles errors during state run":
    var saleFailed = false
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      # raise an exception so machine.onError is called
      raise newException(ValueError, "some error")

    # onClear is called in SaleErrored.run
    sales.onClear = proc(availability: ?Availability,
                         request: StorageRequest,
                         idx: UInt256) =
      saleFailed = true
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually saleFailed

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      raise error
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    await sleepAsync(1.millis)
    without availability =? await reservations.get(availability.id):
      fail()
    check not availability.used

  test "generates proof of storage":
    var provingRequest: StorageRequest
    var provingSlot: UInt256
    proving.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      provingRequest = slot.request
      provingSlot = slot.slotIndex
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually provingRequest == request
    check provingSlot < request.ask.slots.u256

  test "fills a slot":
    check isOk await reservations.reserve(availability)
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
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually soldAvailability == availability
    check soldRequest == request
    check soldSlotIndex < request.ask.slots.u256

  test "calls onClear when storage becomes available again":
    # fail the proof intentionally to trigger `agent.finish(success=false)`,
    # which then calls the onClear callback
    proving.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
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
    check isOk await reservations.reserve(availability)
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
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    await sleepAsync(1.millis)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    await sleepAsync(chronos.seconds(2))
    without availabilities =? (await reservations.allAvailabilities):
      fail()
    check availabilities == @[availability]

  test "makes storage available again when request expires":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         availability: ?Availability) {.async.} =
      await sleepAsync(chronos.hours(1))
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    await sleepAsync(1.millis)
    clock.set(request.expiry.truncate(int64))
    check eventually (await reservations.allAvailabilities) == @[availability]

  test "adds proving for slot when slot is filled":
    var soldSlotIndex: UInt256
    sales.onSale = proc(availability: ?Availability,
                        request: StorageRequest,
                        slotIndex: UInt256) =
      soldSlotIndex = slotIndex
    check proving.slots.len == 0
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually proving.slots.len == 1
    check proving.slots.contains(Slot(request: request, slotIndex: soldSlotIndex))

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
    let expected = SalesData(requestId: request.id,
                             availability: none Availability,
                             request: some request)
    # because sales.load() calls agent.start, we won't know the slotIndex
    # randomly selected for the agent, and we also won't know the value of
    # `failed`/`fulfilled`/`cancelled` futures, so we need to compare
    # the properties we know
    # TODO: when calling sales.load(), slot index should be restored and not
    # randomly re-assigned, so this may no longer be needed
    proc `==` (data0, data1: SalesData): bool =
      return data0.requestId == data1.requestId and
             data0.availability == data1.availability and
             data0.request == data1.request

    check eventually sales.agents.len == 2
    check sales.agents.all(agent => agent.data == expected)
