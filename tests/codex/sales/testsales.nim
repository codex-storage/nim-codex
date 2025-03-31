import std/sequtils
import std/sugar
import std/times
import pkg/chronos
import pkg/datastore/typedds
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
import pkg/codex/utils/asyncstatemachine
import times
import ../../asynctest
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock
import ../helpers/always
import ../examples
import ./helpers/periods

asyncchecksuite "Sales - start":
  let
    proof = Groth16Proof.example
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

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
        slotSize: 100.uint64,
        duration: 60'StorageDuration,
        pricePerBytePerSecond: 1'TokensPerSecond,
        collateralPerByte: 1'Tokens,
      ),
      content: StorageContent(
        cid: Cid.init("zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob").tryGet
      ),
      expiry: 60'StorageDuration,
    )

    market = MockMarket.new()
    clock = MockClock.new()
    let repoDs = repoTmp.newDb()
    let metaDs = metaTmp.newDb()
    repo = RepoStore.new(repoDs, metaDs)
    await repo.start()
    sales = Sales.new(market, clock, repo)
    reservations = sales.context.reservations
    sales.onStore = proc(
        request: StorageRequest,
        expiry: StorageTimestamp,
        slot: uint64,
        onBatch: BatchProc,
        isRepairing = false
    ): Future[?!void] {.async.} =
      return success()

    sales.onExpiryUpdate = proc(
        rootCid: Cid, expiry: SecondsSince1970
    ): Future[?!void] {.async.} =
      return success()

    queue = sales.context.slotQueue
    sales.onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      return success(proof)
    itemsProcessed = @[]

  teardown:
    await sales.stop()
    await repo.stop()
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  proc fillSlot(slotIdx: uint64 = 0.uint64) {.async.} =
    let address = await market.getSigner()
    let slot =
      MockSlot(requestId: request.id, slotIndex: slotIdx, proof: proof, host: address)
    market.filled.add slot
    market.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

  test "load slots when Sales module starts":
    let me = await market.getSigner()

    request.ask.slots = 2
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New

    let slot0 = MockSlot(requestId: request.id, slotIndex: 0, proof: proof, host: me)
    await fillSlot(slot0.slotIndex)

    let slot1 = MockSlot(requestId: request.id, slotIndex: 1, proof: proof, host: me)
    await fillSlot(slot1.slotIndex)

    market.activeSlots[me] = @[request.slotId(0), request.slotId(1)]
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]

    await sales.start()

    check eventually sales.agents.len == 2
    check sales.agents.any(
      agent => agent.data.requestId == request.id and agent.data.slotIndex == 0.uint64
    )
    check sales.agents.any(
      agent => agent.data.requestId == request.id and agent.data.slotIndex == 1.uint64
    )

asyncchecksuite "Sales":
  let
    proof = Groth16Proof.example
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  var totalAvailabilitySize: uint64
  var minPricePerBytePerSecond: TokensPerSecond
  var requestedCollateralPerByte: Tokens
  var totalCollateral: Tokens
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
    totalAvailabilitySize = 100.uint64
    minPricePerBytePerSecond = 1'TokensPerSecond
    requestedCollateralPerByte = 1'Tokens
    totalCollateral = requestedCollateralPerByte * totalAvailabilitySize
    availability = Availability.init(
      totalSize = totalAvailabilitySize,
      freeSize = totalAvailabilitySize,
      duration = 60'StorageDuration,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = totalCollateral,
      enabled = true,
      until = 0'StorageTimestamp,
    )
    request = StorageRequest(
      ask: StorageAsk(
        slots: 4,
        slotSize: 100.uint64,
        duration: 60'StorageDuration,
        pricePerBytePerSecond: minPricePerBytePerSecond,
        collateralPerByte: 1'Tokens,
      ),
      content: StorageContent(
        cid: Cid.init("zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob").tryGet
      ),
      expiry: 60'StorageDuration,
    )

    market = MockMarket.new()

    let me = await market.getSigner()
    market.activeSlots[me] = @[]

    clock = MockClock.new()
    let repoDs = repoTmp.newDb()
    let metaDs = metaTmp.newDb()
    repo = RepoStore.new(repoDs, metaDs)
    await repo.start()
    sales = Sales.new(market, clock, repo)
    reservations = sales.context.reservations
    sales.onStore = proc(
        request: StorageRequest,
        expiry: StorageTimestamp,
        slot: uint64,
        onBatch: BatchProc,
        isRepairing = false
    ): Future[?!void] {.async.} =
      return success()

    sales.onExpiryUpdate = proc(
        rootCid: Cid, expiry: SecondsSince1970
    ): Future[?!void] {.async.} =
      return success()

    queue = sales.context.slotQueue
    sales.onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      return success(proof)
    await sales.start()
    itemsProcessed = @[]

  teardown:
    await sales.stop()
    await repo.stop()
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  proc isInState(idx: int, state: string): bool =
    proc description(state: State): string =
      $state

    if idx >= sales.agents.len:
      return false
    sales.agents[idx].query(description) == state.some

  proc allowRequestToStart() {.async.} =
    check eventually isInState(0, "SaleInitialProving")
    # it won't start proving until the next period
    clock.advanceToNextPeriod(market)

  proc getAvailability(): Availability =
    let key = availability.id.key.get
    (waitFor reservations.get(key, Availability)).get

  proc createAvailability(enabled = true, until = 0'StorageTimestamp) =
    let a = waitFor reservations.createAvailability(
      availability.totalSize, availability.duration,
      availability.minPricePerBytePerSecond, availability.totalCollateral, enabled,
      until,
    )
    availability = a.get # update id

  proc notProcessed(itemsProcessed: seq[SlotQueueItem], request: StorageRequest): bool =
    let collateral = request.ask.collateralPerSlot
    let items = SlotQueueItem.init(request, collateral)
    for i in 0 ..< items.len:
      if itemsProcessed.contains(items[i]):
        return false
    return true

  proc addRequestToSaturatedQueue(): Future[StorageRequest] {.async.} =
    queue.onProcessSlot = proc(
        item: SlotQueueItem, done: Future[void]
    ) {.async: (raises: []).} =
      try:
        await sleepAsync(10.millis)
        itemsProcessed.add item
      except CancelledError as exc:
        checkpoint(exc.msg)
      finally:
        if not done.finished:
          done.complete()

    var request1 = StorageRequest.example
    request1.ask.collateralPerByte = request.ask.collateralPerByte + 1'u8
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
        getAvailability().freeSize == availability.freeSize and
        (waitFor reservations.all(Reservation)).get.len == 0
      )
    waitFor run()

  test "processes all request's slots once StorageRequested emitted":
    queue.onProcessSlot = proc(
        item: SlotQueueItem, done: Future[void]
    ) {.async: (raises: []).} =
      itemsProcessed.add item
      if not done.finished:
        done.complete()
    createAvailability()
    await market.requestStorage(request)
    let collateral = request.ask.collateralPerSlot
    let items = SlotQueueItem.init(request, collateral)
    check eventually items.allIt(itemsProcessed.contains(it))

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
    market.emitSlotFilled(request1.id, 1.uint64)
    let collateral = request1.ask.collateralPerSlot
    let expected = SlotQueueItem.init(request1, 1'u16, collateral)
    check always (not itemsProcessed.contains(expected))

  test "removes slot index from slot queue once SlotReservationsFull emitted":
    let request1 = await addRequestToSaturatedQueue()
    market.emitSlotReservationsFull(request1.id, 1.uint64)
    let collateral = request1.ask.collateralPerSlot
    let expected = SlotQueueItem.init(request1, 1'u16, collateral)
    check always (not itemsProcessed.contains(expected))

  test "adds slot index to slot queue once SlotFreed emitted":
    queue.onProcessSlot = proc(
        item: SlotQueueItem, done: Future[void]
    ) {.async: (raises: []).} =
      itemsProcessed.add item
      if not done.finished:
        done.complete()

    createAvailability()
    market.requested.add request # "contract" must be able to return request

    market.emitSlotFreed(request.id, 2.uint64)

    let collateral = request.ask.collateralPerSlot
    let expected = SlotQueueItem.init(request, 2.uint16, collateral)

    check eventually itemsProcessed.contains(expected)

  test "items in queue are readded (and marked seen) once ignored":
    await market.requestStorage(request)
    let collateral = request.ask.collateralPerSlot
    let items = SlotQueueItem.init(request, collateral)
    check eventually queue.len > 0
      # queue starts paused, allow items to be added to the queue
    check eventually queue.paused
    # The first processed item will be will have been re-pushed with `seen =
    # true`. Then, once this item is processed by the queue, its 'seen' flag
    # will be checked, at which point the queue will be paused. This test could
    # check item existence in the queue, but that would require inspecting
    # onProcessSlot to see which item was first, and overridding onProcessSlot
    # will prevent the queue working as expected in the Sales module.
    check eventually queue.len == 4

    for item in items:
      check queue.contains(item)

    for i in 0 ..< queue.len:
      check queue[i].seen

  test "queue is paused once availability is insufficient to service slots in queue":
    createAvailability() # enough to fill a single slot
    await market.requestStorage(request)
    let collateral = request.ask.collateralPerSlot
    let items = SlotQueueItem.init(request, collateral)
    check eventually queue.len > 0
      # queue starts paused, allow items to be added to the queue
    check eventually queue.paused
    # The first processed item/slot will be filled (eventually). Subsequent
    # items will be processed and eventually re-pushed with `seen = true`. Once
    # a "seen" item is processed by the queue, the queue is paused. In the
    # meantime, the other items that are process, marked as seen, and re-added
    # to the queue may be processed simultaneously as the queue pausing.
    # Therefore, there should eventually be 3 items remaining in the queue, all
    # seen.
    check eventually queue.len == 3
    for i in 0 ..< queue.len:
      check queue[i].seen

  test "availability size is reduced by request slot size when fully downloaded":
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      let blk = bt.Block.new(@[1.byte]).get
      await onBatch(blk.repeat(request.ask.slotSize.int))

    createAvailability()
    await market.requestStorage(request)
    check eventually getAvailability().freeSize ==
      availability.freeSize - request.ask.slotSize

  test "bytes are returned to availability once finished":
    var slotIndex = 0.uint64
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      slotIndex = slot
      let blk = bt.Block.new(@[1.byte]).get
      await onBatch(blk.repeat(request.ask.slotSize))

    let sold = newFuture[void]()
    sales.onSale = proc(request: StorageRequest, slotIndex: uint64) =
      sold.complete()

    createAvailability()
    let origSize = availability.freeSize
    await market.requestStorage(request)
    await allowRequestToStart()
    await sold

    # complete request
    market.slotState[request.slotId(slotIndex)] = SlotState.Finished
    clock.advance(request.ask.duration.u64.int64)

    check eventually getAvailability().freeSize == origSize

  test "ignores download when duration not long enough":
    availability.duration = request.ask.duration - 1'u8
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when slot size is too small":
    availability.totalSize = request.ask.slotSize - 1
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when reward is too low":
    let price = request.ask.pricePerBytePerSecond
    availability.minPricePerBytePerSecond = price + 1'u8
    createAvailability()
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when asked collateral is too high":
    var tooBigCollateral = request
    tooBigCollateral.ask.collateralPerByte = requestedCollateralPerByte + 1
    createAvailability()
    await market.requestStorage(tooBigCollateral)
    check wasIgnored()

  test "ignores request when slot state is not free":
    createAvailability()
    await market.requestStorage(request)
    market.slotState[request.slotId(0.uint64)] = SlotState.Filled
    market.slotState[request.slotId(1.uint64)] = SlotState.Filled
    market.slotState[request.slotId(2.uint64)] = SlotState.Filled
    market.slotState[request.slotId(3.uint64)] = SlotState.Filled
    check wasIgnored()

  test "ignores request when availability is not enabled":
    createAvailability(enabled = false)
    await market.requestStorage(request)
    check wasIgnored()

  test "ignores request when availability until terminates before the duration":
    let until = StorageTimestamp.init(getTime().toUnix())
    createAvailability(until = until)
    await market.requestStorage(request)

    check wasIgnored()

  test "retrieves request when availability until terminates after the duration":
    let requestEnd =
      StorageTimestamp.init(getTime().toUnix()) + request.ask.duration
    let until = requestEnd + 1'StorageDuration
    createAvailability(until = until)

    var storingRequest: StorageRequest
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      storingRequest = request
      return success()

    market.requestEnds[request.id] = requestEnd
    await market.requestStorage(request)
    check eventually storingRequest == request

  test "retrieves and stores data locally":
    var storingRequest: StorageRequest
    var storingSlot: uint64
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      storingRequest = request
      storingSlot = slot
      return success()
    createAvailability()
    await market.requestStorage(request)
    check eventually storingRequest == request
    check storingSlot < request.ask.slots

  test "makes storage available again when data retrieval fails":
    let error = newException(IOError, "data retrieval failed")
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      return failure(error)
    createAvailability()
    await market.requestStorage(request)
    check getAvailability().freeSize == availability.freeSize

  test "generates proof of storage":
    var provingRequest: StorageRequest
    var provingSlot: uint64
    sales.onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      provingRequest = slot.request
      provingSlot = slot.slotIndex
      return success(Groth16Proof.example)
    createAvailability()
    await market.requestStorage(request)
    await allowRequestToStart()

    check eventually provingRequest == request
    check provingSlot < request.ask.slots

  test "fills a slot":
    createAvailability()
    await market.requestStorage(request)
    await allowRequestToStart()

    check eventually market.filled.len > 0
    check market.filled[0].requestId == request.id
    check market.filled[0].slotIndex < request.ask.slots
    check market.filled[0].proof == proof
    check market.filled[0].host == await market.getSigner()

  test "calls onFilled when slot is filled":
    var soldRequest = StorageRequest.default
    var soldSlotIndex = uint64.high
    sales.onSale = proc(request: StorageRequest, slotIndex: uint64) =
      soldRequest = request
      soldSlotIndex = slotIndex
    createAvailability()
    await market.requestStorage(request)
    await allowRequestToStart()

    check eventually soldRequest == request
    check soldSlotIndex < request.ask.slots

  test "calls onClear when storage becomes available again":
    # fail the proof intentionally to trigger `agent.finish(success=false)`,
    # which then calls the onClear callback
    sales.onProve = proc(
        slot: Slot, challenge: ProofChallenge
    ): Future[?!Groth16Proof] {.async.} =
      raise newException(IOError, "proof failed")
    var clearedRequest: StorageRequest
    var clearedSlotIndex: uint64
    sales.onClear = proc(request: StorageRequest, slotIndex: uint64) =
      clearedRequest = request
      clearedSlotIndex = slotIndex
    createAvailability()
    await market.requestStorage(request)
    await allowRequestToStart()

    check eventually clearedRequest == request
    check clearedSlotIndex < request.ask.slots

  test "makes storage available again when other host fills the slot":
    let otherHost = Address.example
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    createAvailability()
    await market.requestStorage(request)
    for slotIndex in 0 ..< request.ask.slots:
      market.fillSlot(request.id, slotIndex.uint64, proof, otherHost)
    check eventually (await reservations.all(Availability)).get == @[availability]

  test "makes storage available again when request expires":
    let origSize = availability.freeSize
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    createAvailability()
    await market.requestStorage(request)

    # If we would not await, then the `clock.set` would run "too fast" as the `subscribeCancellation()`
    # would otherwise not set the timeout early enough as it uses `clock.now` in the deadline calculation.
    await sleepAsync(chronos.milliseconds(100))
    market.requestState[request.id] = RequestState.Cancelled
    clock.set(market.requestExpiry[request.id].toSecondsSince1970 + 1)
    check eventually (await reservations.all(Availability)).get == @[availability]
    check getAvailability().freeSize == origSize

  test "verifies that request is indeed expired from onchain before firing onCancelled":
    # ensure only one slot, otherwise once bytes are returned to the
    # availability, the queue will be unpaused and availability will be consumed
    # by other slots
    request.ask.slots = 1
    market.requestEnds[request.id] =
      StorageTimestamp.init(getTime().toUnix()) + request.ask.duration

    let origSize = availability.freeSize
    sales.onStore = proc(
        request: StorageRequest, expiry: StorageTimestamp, slot: uint64, onBatch: BatchProc, isRepairing = false
    ): Future[?!void] {.async.} =
      await sleepAsync(chronos.hours(1))
      return success()
    createAvailability()
    await market.requestStorage(request)
    market.requestState[request.id] = RequestState.New
      # "On-chain" is the request still ongoing even after local expiration

    # If we would not await, then the `clock.set` would run "too fast" as the `subscribeCancellation()`
    # would otherwise not set the timeout early enough as it uses `clock.now` in the deadline calculation.
    await sleepAsync(chronos.milliseconds(100))
    clock.set(market.requestExpiry[request.id].toSecondsSince1970 + 1)
    check getAvailability().freeSize == 0

    market.requestState[request.id] = RequestState.Cancelled
      # Now "on-chain" is also expired
    check eventually getAvailability().freeSize == origSize

  test "loads active slots from market":
    let me = await market.getSigner()

    request.ask.slots = 2
    market.requested = @[request]
    market.requestState[request.id] = RequestState.New

    proc fillSlot(slotIdx: uint64 = 0) {.async.} =
      let address = await market.getSigner()
      let slot =
        MockSlot(requestId: request.id, slotIndex: slotIdx, proof: proof, host: address)
      market.filled.add slot
      market.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

    let slot0 = MockSlot(requestId: request.id, slotIndex: 0, proof: proof, host: me)
    await fillSlot(slot0.slotIndex)

    let slot1 = MockSlot(requestId: request.id, slotIndex: 1, proof: proof, host: me)
    await fillSlot(slot1.slotIndex)
    market.activeSlots[me] = @[request.slotId(0), request.slotId(1)]
    market.requested = @[request]
    market.activeRequests[me] = @[request.id]

    await sales.load()

    check eventually sales.agents.len == 2
    check sales.agents.any(
      agent => agent.data.requestId == request.id and agent.data.slotIndex == 0.uint64
    )
    check sales.agents.any(
      agent => agent.data.requestId == request.id and agent.data.slotIndex == 1.uint64
    )

  test "deletes inactive reservations on load":
    createAvailability()
    let validUntil = StorageTimestamp.init(getTime().toUnix() + 30)
    discard await reservations.createReservation(
      availability.id, 100.uint64, RequestId.example, 0.uint64, Tokens.example,
      validUntil,
    )
    check (await reservations.all(Reservation)).get.len == 1
    await sales.load()
    check (await reservations.all(Reservation)).get.len == 0
    check getAvailability().freeSize == availability.freeSize # was restored

  test "update an availability fails when trying change the until date before an existing reservation":
    let until = StorageTimestamp.init(getTime().toUnix() + 300)
    createAvailability(until = until)

    market.requestEnds[request.id] =
      StorageTimestamp.init(getTime().toUnix()) + request.ask.duration

    await market.requestStorage(request)
    await allowRequestToStart()

    availability.until = StorageTimestamp.init(getTime().toUnix())

    let result = await reservations.update(availability)
    check result.isErr
    check result.error of UntilOutOfBoundsError
