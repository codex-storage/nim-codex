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
import pkg/codex/blocktype as bt
import pkg/codex/node
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/eventually
import ../examples
import ./helpers

asyncchecksuite "Sales - start":
  let proof = exampleProof()

  var request: StorageRequest
  var sales: Sales
  var market: MockMarket
  var clock: MockClock
  var proving: Proving
  var reservations: Reservations
  var repo: RepoStore
  var queue: SlotQueue
  var itemsProcessed: seq[SlotQueueItem]

  setup:
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
    itemsProcessed = @[]
    request.expiry = (clock.now() + 42).u256

  teardown:
    await sales.stop()
    await repo.stop()

  proc fillSlot(slotIdx: UInt256 = 0.u256) {.async.} =
    let address = await market.getSigner()
    let slot = MockSlot(requestId: request.id,
                        slotIndex: slotIdx,
                        proof: proof,
                        host: address)
    market.filled.add slot
    market.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

  test "load slots when Sales module starts":
    let me = await market.getSigner()

    request.ask.slots = 2
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New

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

    await sales.start()

    check eventually sales.agents.len == 2
    check sales.agents.any(agent => agent.data.requestId == request.id and agent.data.slotIndex == 0.u256)
    check sales.agents.any(agent => agent.data.requestId == request.id and agent.data.slotIndex == 1.u256)

asyncchecksuite "Sales":
  let proof = exampleProof()

  var availability: Availability
  var request: StorageRequest
  var sales: Sales
  var market: MockMarket
  var clock: MockClock
  var reservations: Reservations
  var repo: RepoStore
  var queue: SlotQueue
  var itemsProcessed: seq[SlotQueueItem]

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

    let me = await market.getSigner()
    market.activeSlots[me] = @[]

    clock = MockClock.new()
    let repoDs = SQLiteDatastore.new(Memory).tryGet()
    let metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    await repo.start()
    sales = Sales.new(market, clock, repo)
    reservations = sales.context.reservations
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      return success()
    queue = sales.context.slotQueue
    sales.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      return proof
    await sales.start()
    request.expiry = (clock.now() + 42).u256
    itemsProcessed = @[]

  teardown:
    await sales.stop()
    await repo.stop()

  proc getAvailability: ?!Availability =
    waitFor reservations.get(availability.id)

  proc notProcessed(itemsProcessed: seq[SlotQueueItem],
                    request: StorageRequest): bool =
    let items = SlotQueueItem.init(request)
    for i in 0..<items.len:
      if itemsProcessed.contains(items[i]):
        return false
    return true

  proc addRequestToSaturatedQueue(): Future[StorageRequest] {.async.} =
    queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      await sleepAsync(10.millis)
      itemsProcessed.add item
      done.complete()

    var request1 = StorageRequest.example
    request1.ask.collateral = request.ask.collateral + 1
    discard await reservations.reserve(availability)
    await market.requestStorage(request)
    await market.requestStorage(request1)
    await sleepAsync(5.millis) # wait for request slots to be added to queue
    return request1

  test "processes all request's slots once StorageRequested emitted":
   queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
                           itemsProcessed.add item
                           done.complete()
   check isOk await reservations.reserve(availability)
   await market.requestStorage(request)
   let items = SlotQueueItem.init(request)
   check eventually items.allIt(itemsProcessed.contains(it))

  test "removes slots from slot queue once RequestCancelled emitted":
   let request1 = await addRequestToSaturatedQueue()
   market.emitRequestCancelled(request1.id)
   check always itemsProcessed.notProcessed(request1)

  test "removes request from slot queue once RequestFailed emitted":
   let request1 = await addRequestToSaturatedQueue()
   market.emitRequestFailed(request1.id)
   check always itemsProcessed.notProcessed(request1)

  test "removes request from slot queue once RequestFulfilled emitted":
   let request1 = await addRequestToSaturatedQueue()
   market.emitRequestFulfilled(request1.id)
   check always itemsProcessed.notProcessed(request1)

  test "removes slot index from slot queue once SlotFilled emitted":
   let request1 = await addRequestToSaturatedQueue()
   market.emitSlotFilled(request1.id, 1.u256)
   let expected = SlotQueueItem.init(request1, 1'u16)
   check always (not itemsProcessed.contains(expected))

  test "adds slot index to slot queue once SlotFreed emitted":
   queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
     itemsProcessed.add item
     done.complete()

   check isOk await reservations.reserve(availability)
   market.requested.add request # "contract" must be able to return request
   market.emitSlotFreed(request.id, 2.u256)

   let expected = SlotQueueItem.init(request, 2.uint16)
   check eventually itemsProcessed.contains(expected)

  test "request slots are not added to the slot queue when no availabilities exist":
   var itemsProcessed: seq[SlotQueueItem] = @[]
   queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
     itemsProcessed.add item
     done.complete()

   await market.requestStorage(request)
   # check that request was ignored due to no matching availability
   check always itemsProcessed.len == 0

  test "non-matching availabilities/requests are not added to the slot queue":
   var itemsProcessed: seq[SlotQueueItem] = @[]
   queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
     itemsProcessed.add item
     done.complete()

   let nonMatchingAvailability = Availability.init(
     size=100.u256,
     duration=60.u256,
     minPrice=601.u256, # too high
     maxCollateral=400.u256
   )
   check isOk await reservations.reserve(nonMatchingAvailability)
   await market.requestStorage(request)
   # check that request was ignored due to no matching availability
   check always itemsProcessed.len == 0

  test "adds past requests to queue once availability added":
   var itemsProcessed: seq[SlotQueueItem] = @[]
   queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
     itemsProcessed.add item
     done.complete()

   await market.requestStorage(request)

   # now add matching availability
   check isOk await reservations.reserve(availability)
   check eventuallyCheck itemsProcessed.len == request.ask.slots.int

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
    sales.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
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
    sales.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
      provingRequest = slot.request
      provingSlot = slot.slotIndex
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventually provingRequest == request
    check provingSlot < request.ask.slots.u256

  test "fills a slot":
    check isOk await reservations.reserve(availability)
    await market.requestStorage(request)
    check eventuallyCheck market.filled.len == 1
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
    sales.onProve = proc(slot: Slot): Future[seq[byte]] {.async.} =
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

    check eventually sales.agents.len == 2
    check sales.agents.any(agent => agent.data.requestId == request.id and agent.data.slotIndex == 0.u256)
    check sales.agents.any(agent => agent.data.requestId == request.id and agent.data.slotIndex == 1.u256)
