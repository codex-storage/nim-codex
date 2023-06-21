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
import pkg/codex/sales/salescontext
import pkg/codex/sales/reservations
import pkg/codex/sales/slotqueue
import pkg/codex/stores/repostore
import pkg/codex/proving
import pkg/codex/blocktype as bt
import pkg/codex/node
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples
import ./helpers

asyncchecksuite "Sales":
  let proof = exampleProof()

  var availability: Availability
  var request: StorageRequest
  var sales: Sales
  var market: MockMarket
  var clock: MockClock
  var proving: Proving
  var reservations: Reservations
  var repo: RepoStore
  var queue: SlotQueue

  setup:
    availability = Availability.init(
      size=100.u256,
      duration=60.u256,
      minPrice=600.u256,
      maxCollateral=400.u256
    )
    request = StorageRequest(
      ask: StorageAsk(
        slots: 4,
        slotSize: 100.u256,
        duration: 60.u256,
        reward: 10.u256,
        collateral: 200.u256,
      ),
      content: StorageContent(
        cid: "some cid"
      ),
      expiry: (getTime() + initDuration(hours=1)).toUnix.u256
    )

    market = MockMarket.new()
    clock = MockClock.new()
    proving = Proving.new()
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    await repo.start()
    sales = Sales.new(market, clock, proving, repo)
    reservations = sales.context.reservations
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      return success()
    queue = sales.context.slotQueue
    proving.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256

  teardown:
    await repo.stop()
    await sales.stop()

  proc getAvailability: ?!Availability =
    waitFor reservations.get(availability.id)

  proc waitUntilInQueue(sqis: seq[SlotQueueItem]) {.async.} =
    for i in 0..<sqis.len:
      check eventually queue.contains(sqis[i])

  test "processes all request's slots once StorageRequested emitted":
    var slotsProcessed: seq[SlotQueueItem] = @[]
    queue.onProcessSlot = proc(sqi: SlotQueueItem, processing: Future[void]) {.async.} =
                            slotsProcessed.add sqi
                            processing.complete()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    let sqis = SlotQueueItem.init(request)
    check eventually sqis.allIt(slotsProcessed.contains(it))

  test "adds request's slots to slot queue once StorageRequested emitted":
    queue.stop() # prevents popping during processing
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    let sqis = SlotQueueItem.init(request)
    await waitUntilInQueue(sqis)

  test "removes slots from slot queue once RequestCancelled emitted":
    queue.stop() # prevents popping during processing
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    let sqis = SlotQueueItem.init(request)
    await waitUntilInQueue(sqis)
    market.emitRequestCancelled(request.id)
    check queue.len == 0

  test "removes request from slot queue once RequestFailed emitted":
    queue.stop() # prevents popping during processing
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    let sqis = SlotQueueItem.init(request)
    await waitUntilInQueue(sqis)
    market.emitRequestFailed(request.id)
    check queue.len == 0

  test "all slots for request are added to queue once requested":
    queue.stop() # prevents popping during processing
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    for slotIndex in 0'u64..<request.ask.slots:
      let sqi = SlotQueueItem.init(request, slotIndex)
      check eventually queue.contains(sqi)

  test "removes slot index from slot queue once SlotFilled emitted":
    queue.stop() # preventing popping during processing loop
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    let sqis = SlotQueueItem.init(request)
    await waitUntilInQueue(sqis)
    market.emitSlotFilled(request.id, 1.u256)
    check queue.len == 3
    check not queue.contains(SlotQueueItem.init(request, 1.uint64))
    for slotIndex in [0'u64, 2'u64, 3'u64]:
      let sqi = SlotQueueItem.init(request, slotIndex)
      check queue.contains(sqi)

  test "all request's slots removed from queue once SlotFulfilled emitted":
    queue.stop()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    market.emitRequestFulfilled(request.id)
    check queue.len == 0

  test "adds slot index to slot queue once SlotFreed emitted":
    queue.stop() # prevents popping during processing
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    market.emitSlotFilled(request.id, 0.u256)
    market.emitSlotFilled(request.id, 1.u256)
    market.emitSlotFilled(request.id, 2.u256)
    market.emitSlotFilled(request.id, 3.u256)
    check queue.len == 0
    market.emitSlotFreed(request.id, 2.u256)
    check queue.len == 1
    check queue[0].slotIndex == 2'u64

  test "removes request in queue if unknown request once SlotFreed emitted":
    queue.stop()
    let sqis = SlotQueueItem.init(request)
    check queue.push(sqis).isOk
    market.emitSlotFreed(request.id, 2.u256)
    check queue.len == 0

  test "makes storage unavailable when downloading a matched request":
    var used = false
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      without avail =? await reservations.get(availability.id):
        fail()
      used = avail.used
      return success()

    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually used

  test "reduces remaining availability size after download":
    let blk = bt.Block.example
    request.ask.slotSize = blk.data.len.u256
    availability.size = request.ask.slotSize + 1
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      await onBatch(@[blk])
      return success()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually getAvailability().?size == success 1.u256

  test "ignores download when duration not long enough":
    availability.duration = request.ask.duration - 1
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check getAvailability().?size == success availability.size

  test "ignores request when slot size is too small":
    availability.size = request.ask.slotSize - 1
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check getAvailability().?size == success availability.size

  test "ignores request when reward is too low":
    availability.minPrice = request.ask.pricePerSlot + 1
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check getAvailability().?size == success availability.size

  test "availability remains unused when request is ignored":
    availability.minPrice = request.ask.pricePerSlot + 1
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check getAvailability().?used == success false

  test "ignores request when asked collateral is too high":
    var tooBigCollateral = request
    tooBigCollateral.ask.collateral = availability.maxCollateral + 1
    check isOk await reservations.reserve(availability)
    await market.requestStorage(tooBigCollateral)
    check getAvailability().?size == success availability.size

  test "ignores request when slot state is not free":
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    market.slotState[request.slotId(0.u256)] = SlotState.Filled
    market.slotState[request.slotId(1.u256)] = SlotState.Filled
    market.slotState[request.slotId(2.u256)] = SlotState.Filled
    market.slotState[request.slotId(3.u256)] = SlotState.Filled
    check getAvailability().?size == success availability.size

  test "retrieves and stores data locally":
    var storingRequest: StorageRequest
    var storingSlot: UInt256
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      storingRequest = request
      storingSlot = slot
      return success()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually storingRequest == request
    check storingSlot < request.ask.slots.u256

  test "handles errors during state run":
    var saleFailed = false
    proving.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      # raise exception so machine.onError is called
      raise newException(ValueError, "some error")

    # onClear is called in SaleErrored.run
    sales.onClear = proc(request: StorageRequest,
                         idx: UInt256) =
      saleFailed = true
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually saleFailed

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      return failure(error)
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually getAvailability().?used == success false
    check getAvailability().?size == success availability.size

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
    sales.onSale = proc(request: StorageRequest,
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
    var clearedRequest: StorageRequest
    var clearedSlotIndex: UInt256
    sales.onClear = proc(request: StorageRequest,
                         slotIndex: UInt256) =
      clearedRequest = request
      clearedSlotIndex = slotIndex
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually clearedRequest == request
    check clearedSlotIndex < request.ask.slots.u256

  test "makes storage available again when other host fills the slot":
    let otherHost = Address.example
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    check eventually (await reservations.allAvailabilities) == @[availability]

  test "makes storage available again when request expires":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    clock.set(request.expiry.truncate(int64))
    check eventually (await reservations.allAvailabilities) == @[availability]

  test "adds proving for slot when slot is filled":
    var soldSlotIndex: UInt256
    sales.onSale = proc(request: StorageRequest,
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
    let expected = SalesData(requestId: request.id, request: some request)
    # because sales.load() calls agent.start, we won't know the slotIndex
    # randomly selected for the agent, and we also won't know the value of
    # `failed`/`fulfilled`/`cancelled` futures, so we need to compare
    # the properties we know
    # TODO: when calling sales.load(), slot index should be restored and not
    # randomly re-assigned, so this may no longer be needed
    proc `==` (data0, data1: SalesData): bool =
      return data0.requestId == data1.requestId and
             data0.request == data1.request

    check eventually sales.agents.len == 2
    check sales.agents.all(agent => agent.data == expected)
