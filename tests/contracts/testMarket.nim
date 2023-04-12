import std/options
import pkg/chronos
import pkg/stew/byteutils
import codex/contracts
import ../ethertest
import ./examples
import ./time

ethersuite "On-Chain Market":
  let proof = exampleProof()

  var market: OnChainMarket
  var marketplace: Marketplace
  var request: StorageRequest
  var slotIndex: UInt256
  var periodicity: Periodicity

  setup:
    let deployment = Deployment.init()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider.getSigner())
    let config = await marketplace.config()

    market = OnChainMarket.new(marketplace)
    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = accounts[0]

    slotIndex = (request.ask.slots div 2).u256

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    ):
      await provider.advanceTime(periodicity.seconds)

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = marketplace.connect(provider)
    expect AssertionDefect:
      discard OnChainMarket.new(storageWithoutSigner)

  test "knows signer address":
    check (await market.getSigner()) == (await provider.getSigner().getAddress())

  test "can retrieve proof periodicity":
    let periodicity = await market.periodicity()
    let config = await marketplace.config()
    let periodLength = config.proofs.period
    check periodicity.seconds == periodLength

  test "can retrieve proof timeout":
    let proofTimeout = await market.proofTimeout()
    let config = await marketplace.config()
    check proofTimeout == config.proofs.timeout

  test "supports marketplace requests":
    await market.requestStorage(request)

  test "can retrieve previously submitted requests":
    check (await market.getRequest(request.id)) == none StorageRequest
    await market.requestStorage(request)
    let r = await market.getRequest(request.id)
    check (r) == some request

  test "supports withdrawing of funds":
    await market.requestStorage(request)
    await provider.advanceTimeTo(request.expiry)
    await market.withdrawFunds(request.id)

  test "supports request subscriptions":
    var receivedIds: seq[RequestId]
    var receivedAsks: seq[StorageAsk]
    proc onRequest(id: RequestId, ask: StorageAsk) =
      receivedIds.add(id)
      receivedAsks.add(ask)
    let subscription = await market.subscribeRequests(onRequest)
    await market.requestStorage(request)
    check receivedIds == @[request.id]
    check receivedAsks == @[request.ask]
    await subscription.unsubscribe()

  test "supports filling of slots":
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)

  test "can retrieve host that filled slot":
    await market.requestStorage(request)
    check (await market.getHost(request.id, slotIndex)) == none Address
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check (await market.getHost(request.id, slotIndex)) == some accounts[0]

  test "supports freeing a slot":
    await token.approve(marketplace.address, request.price)
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof)
    await market.freeSlot(slotId(request.id, slotIndex))
    check (await market.getHost(request.id, slotIndex)) == none Address

  test "supports checking whether proof is required now":
    check (await market.isProofRequired(slotId(request.id, slotIndex))) == false

  test "supports checking whether proof is required soon":
    check (await market.willProofBeRequired(slotId(request.id, slotIndex))) == false

  test "submits proofs":
    await market.submitProof(slotId(request.id, slotIndex), proof)

  test "can mark a proof as missing":
    let slotId = slotId(request, slotIndex)
    await token.approve(marketplace.address, request.price)
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    await market.markProofAsMissing(slotId, missingPeriod)
    check (await marketplace.missingProofs(slotId)) == 1

  test "supports slot filled subscriptions":
    await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(id: RequestId, slotIndex: UInt256) =
      receivedIds.add(id)
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(onSlotFilled)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check receivedIds == @[request.id]
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "subscribes only to a certain slot":
    var otherSlot = slotIndex - 1
    await market.requestStorage(request)
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(request.id, slotIndex, onSlotFilled)
    await market.fillSlot(request.id, otherSlot, proof, request.ask.collateral)
    check receivedSlotIndices.len == 0
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "supports slot freed subscriptions":
    await token.approve(marketplace.address, request.price)
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof)
    var receivedIds: seq[SlotId]
    proc onSlotFreed(id: SlotId) =
      receivedIds.add(id)
    let subscription = await market.subscribeSlotFreed(onSlotFreed)
    await market.freeSlot(slotId(request.id, slotIndex))
    check receivedIds == @[slotId(request.id, slotIndex)]
    await subscription.unsubscribe()

  test "support fulfillment subscriptions":
    await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)
    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to fulfillment of a certain request":
    var otherRequest = StorageRequest.example
    otherRequest.client = accounts[0]

    await market.requestStorage(request)
    await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)

    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)

    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    for slotIndex in 0..<otherRequest.ask.slots:
      await market.fillSlot(otherRequest.id, slotIndex.u256, proof, otherRequest.ask.collateral)

    check receivedIds == @[request.id]

    await subscription.unsubscribe()

  test "support request cancelled subscriptions":
    await market.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)

    await provider.advanceTimeTo(request.expiry)
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "support request failed subscriptions":
    await market.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestFailed(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeRequestFailed(request.id, onRequestFailed)

    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    for slotIndex in 0..request.ask.maxSlotLoss:
      let slotId = request.slotId(slotIndex.u256)
      while true:
        let slotState = await marketplace.slotState(slotId)
        if slotState == SlotState.Free:
          break
        await waitUntilProofRequired(slotId)
        let missingPeriod = periodicity.periodOf(await provider.currentTime())
        await provider.advanceTime(periodicity.seconds)
        await marketplace.markProofAsMissing(slotId, missingPeriod)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to a certain request cancellation":
    var otherRequest = request
    otherRequest.nonce = Nonce.example
    await market.requestStorage(request)
    await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(requestId: RequestId) =
      receivedIds.add(requestId)

    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)
    await provider.advanceTimeTo(request.expiry) # shares expiry with otherRequest
    await market.withdrawFunds(otherRequest.id)
    check receivedIds.len == 0
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "supports proof submission subscriptions":
    var receivedIds: seq[SlotId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await market.subscribeProofSubmission(onProofSubmission)

    await market.submitProof(slotId(request.id, slotIndex), proof)

    check receivedIds == @[slotId(request.id, slotIndex)]
    check receivedProofs == @[proof]

    await subscription.unsubscribe()

  test "request is none when unknown":
    check isNone await market.getRequest(request.id)

  test "can retrieve active requests":
    await market.requestStorage(request)
    var request2 = StorageRequest.example
    request2.client = accounts[0]
    await market.requestStorage(request2)
    check (await market.myRequests()) == @[request.id, request2.id]

  test "retrieves correct request state when request is unknown":
    check (await market.requestState(request.id)) == none RequestState

  test "can retrieve request state":
    await market.requestStorage(request)
    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof, request.ask.collateral)
    check (await market.requestState(request.id)) == some RequestState.Started

  test "can retrieve active slots":
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex - 1, proof, request.ask.collateral)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId1 = request.slotId(slotIndex - 1)
    let slotId2 = request.slotId(slotIndex)
    check (await market.mySlots()) == @[slotId1, slotId2]

  test "returns none when slot is empty":
    await market.requestStorage(request)
    let slotId = request.slotId(slotIndex)
    check (await market.getActiveSlot(slotId)) == none Slot

  test "can retrieve request details from slot id":
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId = request.slotId(slotIndex)
    let expected = Slot(request: request, slotIndex: slotIndex)
    check (await market.getActiveSlot(slotId)) == some expected

  test "retrieves correct slot state when request is unknown":
    let slotId = request.slotId(slotIndex)
    check (await market.slotState(slotId)) == SlotState.Free

  test "retrieves correct slot state once filled":
    await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof, request.ask.collateral)
    let slotId = request.slotId(slotIndex)
    check (await market.slotState(slotId)) == SlotState.Filled
