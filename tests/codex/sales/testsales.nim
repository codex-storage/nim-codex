import std/sequtils
import std/sugar
import std/times
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
import ../../asynctest
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/always
import ../examples

asyncchecksuite "Sales - start":
  let proof = exampleProof()

  var request: StorageRequest
  var sales: Sales
  var market: MockMarket
  var clock: MockClock
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

    sales.onExpiryUpdate = proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] {.async.} =
      return success()

    queue = sales.context.slotQueue
    sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      return success(proof)
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
    availability = Availability(
      size: 100.u256,
      duration: 60.u256,
      minPrice: 600.u256,
      maxCollateral: 400.u256
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
    market.requestEnds[request.id] = request.expiry.toSecondsSince1970

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

    sales.onExpiryUpdate = proc(rootCid: string, expiry: SecondsSince1970): Future[?!void] {.async.} =
      return success()

    queue = sales.context.slotQueue
    sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      return success(proof)
    await sales.start()
    itemsProcessed = @[]

  teardown:
    await sales.stop()
    await repo.stop()

  proc getAvailability: Availability =
    let key = availability.id.key.get
    (waitFor reservations.get(key, Availability)).get

  proc createAvailability() =
    let a = waitFor reservations.createAvailability(
      availability.size,
      availability.duration,
      availability.minPrice,
      availability.maxCollateral
    )
    availability = a.get # update id

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
    createAvailability()
    # saturate queue
    while queue.len < queue.size - 1:
      await market.requestStorage(StorageRequest.example)
    # send request
    await market.requestStorage(request1)
    await sleepAsync(5.millis) # wait for request slots to be added to queue
    return request1

  proc wasIgnored(): bool =
    let run = proc(): Future[bool] {.async.} =
      always (
        getAvailability().size == availability.size and
        (waitFor reservations.all(Reservation)).get.len == 0
      )
    waitFor run()

  test "processes all request's slots once StorageRequested emitted":
    queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
                            itemsProcessed.add item
                            done.complete()
    createAvailability()
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

    createAvailability()
    market.requested.add request # "contract" must be able to return request
    market.emitSlotFreed(request.id, 2.u256)

    let expected = SlotQueueItem.init(request, 2.uint16)
    check eventually itemsProcessed.contains(expected)

  test "adds past requests to queue once availability added":
    var itemsProcessed: seq[SlotQueueItem] = @[]

    # ignore all
    queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      done.complete()

    await market.requestStorage(request)
    await sleepAsync(10.millis)

    # check how many slots were processed by the queue
    queue.onProcessSlot = proc(item: SlotQueueItem, done: Future[void]) {.async.} =
      itemsProcessed.add item
      done.complete()

    # now add matching availability
    createAvailability()
    check eventually itemsProcessed.len == request.ask.slots.int

  test "availability size is reduced by request slot size when fully downloaded":
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      let blk = bt.Block.new( @[1.byte] ).get
      onBatch( blk.repeat(request.ask.slotSize.truncate(int)) )
      return success()

    createAvailability()
    await market.requestStorage(request)
    check eventually getAvailability().size == availability.size - request.ask.slotSize

  test "non-downloaded bytes are returned to availability once finished":
    var slotIndex = 0.u256
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      slotIndex = slot
      let blk = bt.Block.new( @[1.byte] ).get
      onBatch(@[ blk ])
      return success()
    let sold = newFuture[void]()
    sales.onSale = proc(request: StorageRequest, slotIndex: UInt256) =
      sold.complete()

    createAvailability()
    let origSize = availability.size
    await market.requestStorage(request)
    await sold # allow proving to start

    # complete request
    market.slotState[request.slotId(slotIndex)] = SlotState.Finished
    clock.advance(request.ask.duration.truncate(int64))

    check eventually getAvailability().size == origSize - 1

  test "ignores download when duration not long enough":
    availability.duration = request.ask.duration - 1
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when slot size is too small":
    availability.size = request.ask.slotSize - 1
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when reward is too low":
    availability.minPrice = request.ask.pricePerSlot + 1
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when asked collateral is too high":
    var tooBigCollateral = request
    tooBigCollateral.ask.collateral = availability.maxCollateral + 1
    createAvailability()
    await market.requestStorage(tooBigCollateral)
    check wasIgnored()

  test "ignores request when slot state is not free":
    createAvailability()
    await market.requestStorage(request)
    market.slotState[request.slotId(0.u256)] = SlotState.Filled
    market.slotState[request.slotId(1.u256)] = SlotState.Filled
    market.slotState[request.slotId(2.u256)] = SlotState.Filled
    market.slotState[request.slotId(3.u256)] = SlotState.Filled
    check wasIgnored()

  test "retrieves and stores data locally":
    var storingRequest: StorageRequest
    var storingSlot: UInt256
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      storingRequest = request
      storingSlot = slot
      return success()
    createAvailability()
    await market.requestStorage(request)
    check eventually storingRequest == request
    check storingSlot < request.ask.slots.u256

  test "handles errors during state run":
    var saleFailed = false
    sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      # raise exception so machine.onError is called
      raise newException(ValueError, "some error")

    # onClear is called in SaleErrored.run
    sales.onClear = proc(request: StorageRequest,
                         idx: UInt256) =
      saleFailed = true
    createAvailability()
    await market.requestStorage(request)
    check eventually saleFailed

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      return failure(error)
    createAvailability()
    await market.requestStorage(request)
    check getAvailability().size == availability.size

  test "generates proof of storage":
    var provingRequest: StorageRequest
    var provingSlot: UInt256
    sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      provingRequest = slot.request
      provingSlot = slot.slotIndex
      return success(exampleProof())
    createAvailability()
    await market.requestStorage(request)
    check eventually provingRequest == request
    check provingSlot < request.ask.slots.u256

  test "fills a slot":
    createAvailability()
    await market.requestStorage(request)
    check eventually market.filled.len > 0
    check market.filled[0].requestId == request.id
    check market.filled[0].slotIndex < request.ask.slots.u256
    check market.filled[0].proof == proof
    check market.filled[0].host == await market.getSigner()

  test "calls onFilled when slot is filled":
    var soldRequest = StorageRequest.default
    var soldSlotIndex = UInt256.high
    sales.onSale = proc(request: StorageRequest,
                        slotIndex: UInt256) =
      soldRequest = request
      soldSlotIndex = slotIndex
    createAvailability()
    await market.requestStorage(request)
    check eventually soldRequest == request
    check soldSlotIndex < request.ask.slots.u256

  test "calls onClear when storage becomes available again":
    # fail the proof intentionally to trigger `agent.finish(success=false)`,
    # which then calls the onClear callback
    sales.onProve = proc(slot: Slot, challenge: ProofChallenge): Future[?!seq[byte]] {.async.} =
      raise newException(IOError, "proof failed")
    var clearedRequest: StorageRequest
    var clearedSlotIndex: UInt256
    sales.onClear = proc(request: StorageRequest,
                         slotIndex: UInt256) =
      clearedRequest = request
      clearedSlotIndex = slotIndex
    createAvailability()
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
    createAvailability()
    await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      market.fillSlot(request.id, slotIndex.u256, proof, otherHost)
    check eventually (await reservations.all(Availability)).get == @[availability]

  test "makes storage available again when request expires":
    let origSize = availability.size
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    createAvailability()
    await market.requestStorage(request)

    # If we would not await, then the `clock.set` would run "too fast" as the `subscribeCancellation()`
    # would otherwise not set the timeout early enough as it uses `clock.now` in the deadline calculation.
    await sleepAsync(chronos.milliseconds(100))
    market.requestState[request.id]=RequestState.Cancelled
    clock.set(request.expiry.truncate(int64)+1)
    check eventually (await reservations.all(Availability)).get == @[availability]
    check getAvailability().size == origSize

  test "verifies that request is indeed expired from onchain before firing onCancelled":
    let origSize = availability.size
    sales.onStore = proc(request: StorageRequest,
                         slot: UInt256,
                         onBatch: BatchProc): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    createAvailability()
    await market.requestStorage(request)
    market.requestState[request.id]=RequestState.New # "On-chain" is the request still ongoing even after local expiration

    # If we would not await, then the `clock.set` would run "too fast" as the `subscribeCancellation()`
    # would otherwise not set the timeout early enough as it uses `clock.now` in the deadline calculation.
    await sleepAsync(chronos.milliseconds(100))
    clock.set(request.expiry.truncate(int64)+1)
    check getAvailability().size == 0

    market.requestState[request.id]=RequestState.Cancelled # Now "on-chain" is also expired
    check eventually getAvailability().size == origSize

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

  test "deletes inactive reservations on load":
    createAvailability()
    discard await reservations.createReservation(
      availability.id,
      100.u256,
      RequestId.example,
      UInt256.example)
    check (await reservations.all(Reservation)).get.len == 1
    await sales.load()
    check (await reservations.all(Reservation)).get.len == 0
    check getAvailability().size == availability.size # was restored
