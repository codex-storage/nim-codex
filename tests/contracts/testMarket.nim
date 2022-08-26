import pkg/chronos
import codex/contracts
import codex/contracts/testtoken
import stew/byteutils # delete me
import ../ethertest
import ./examples
import ./time

ethersuite "On-Chain Market":
  let proof = seq[byte].example

  var market: OnChainMarket
  var storage: Storage
  var token: TestToken
  var request: StorageRequest
  var slotIndex: UInt256

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1_000_000_000.u256)

    let collateral = await storage.collateralAmount()
    await token.approve(storage.address, collateral)
    await storage.deposit(collateral)

    market = OnChainMarket.new(storage)

    request = StorageRequest.example
    request.client = accounts[0]

    slotIndex = (request.ask.slots div 2).u256

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = storage.connect(provider)
    expect AssertionError:
      discard OnChainMarket.new(storageWithoutSigner)

  test "knows signer address":
    check (await market.getSigner()) == (await provider.getSigner().getAddress())

  test "supports storage requests":
    await token.approve(storage.address, request.price)
    check (await market.requestStorage(request)) == request

  test "sets client address when submitting storage request":
    var requestWithoutClient = request
    requestWithoutClient.client = Address.default
    await token.approve(storage.address, request.price)
    let submitted = await market.requestStorage(requestWithoutClient)
    check submitted.client == accounts[0]

  test "can retrieve previously submitted requests":
    check (await market.getRequest(request.id)) == none StorageRequest
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    let r = await market.getRequest(request.id)
    check (r) == some request

  test "supports withdrawing of funds":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    await provider.advanceTimeTo(request.expiry)
    await market.withdrawFunds(request.id)

  test "supports request subscriptions":
    var receivedIds: seq[RequestId]
    var receivedAsks: seq[StorageAsk]
    proc onRequest(id: RequestId, ask: StorageAsk) =
      receivedIds.add(id)
      receivedAsks.add(ask)
    let subscription = await market.subscribeRequests(onRequest)
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    check receivedIds == @[request.id]
    check receivedAsks == @[request.ask]
    await subscription.unsubscribe()

  test "supports filling of slots":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    await market.fillSlot(request.id, slotIndex, proof)

  test "can retrieve host that filled slot":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    check (await market.getHost(request.id, slotIndex)) == none Address
    await market.fillSlot(request.id, slotIndex, proof)
    check (await market.getHost(request.id, slotIndex)) == some accounts[0]

  test "support slot filled subscriptions":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(id: RequestId, slotIndex: UInt256) =
      receivedIds.add(id)
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(request.id, slotIndex, onSlotFilled)
    await market.fillSlot(request.id, slotIndex, proof)
    check receivedIds == @[request.id]
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "subscribes only to a certain slot":
    var otherSlot = slotIndex - 1
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    var receivedSlotIndices: seq[UInt256]
    proc onSlotFilled(requestId: RequestId, slotIndex: UInt256) =
      receivedSlotIndices.add(slotIndex)
    let subscription = await market.subscribeSlotFilled(request.id, slotIndex, onSlotFilled)
    await market.fillSlot(request.id, slotIndex - 1, proof)
    check receivedSlotIndices.len == 0
    await market.fillSlot(request.id, slotIndex, proof)
    check receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "support fulfillment subscriptions":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)
    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to fulfillment of a certain request":
    var otherRequest = StorageRequest.example
    otherRequest.client = accounts[0]

    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    await token.approve(storage.address, otherRequest.price)
    discard await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)

    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)

    for slotIndex in 0..<request.ask.slots:
      await market.fillSlot(request.id, slotIndex.u256, proof)
    for slotIndex in 0..<otherRequest.ask.slots:
      await market.fillSlot(otherRequest.id, slotIndex.u256, proof)

    check receivedIds == @[request.id]

    await subscription.unsubscribe()

  test "support request cancelled subscriptions":
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(id: RequestId) =
      receivedIds.add(id)
    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)

    await provider.advanceTimeTo(request.expiry)
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to a certain request cancellation":
    let otherRequest = StorageRequest.example
    await token.approve(storage.address, request.price)
    discard await market.requestStorage(request)
    await token.approve(storage.address, otherRequest.price)
    discard await market.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(requestId: RequestId) =
      receivedIds.add(requestId)

    let subscription = await market.subscribeRequestCancelled(request.id, onRequestCancelled)
    await provider.advanceTimeTo(request.expiry) # shares expiry with otherRequest
    expect ValueError:
      await market.withdrawFunds(otherRequest.id)
    check receivedIds.len == 0
    await market.withdrawFunds(request.id)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()
