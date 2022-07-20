import pkg/chronos
import codex/contracts
import codex/contracts/testtoken
import ../ethertest
import ./examples
import ./time

ethersuite "On-Chain Market":
  let proof = seq[byte].example

  var market: OnChainMarket
  var storage: Storage
  var token: TestToken
  var request: StorageRequest

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1000.u256)

    let collateral = await storage.collateralAmount()
    await token.approve(storage.address, collateral)
    await storage.deposit(collateral)

    market = OnChainMarket.new(storage)

    request = StorageRequest.example
    request.client = accounts[0]

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = storage.connect(provider)
    expect AssertionError:
      discard OnChainMarket.new(storageWithoutSigner)

  test "knows signer address":
    check (await market.getSigner()) == (await provider.getSigner().getAddress())

  test "supports storage requests":
    await token.approve(storage.address, request.ask.reward)
    check (await market.requestStorage(request)) == request

  test "sets client address when submitting storage request":
    var requestWithoutClient = request
    requestWithoutClient.client = Address.default
    await token.approve(storage.address, request.ask.reward)
    let submitted = await market.requestStorage(requestWithoutClient)
    check submitted.client == accounts[0]

  test "can retrieve previously submitted requests":
    check (await market.getRequest(request.id)) == none StorageRequest
    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    check (await market.getRequest(request.id)) == some request

  test "supports request subscriptions":
    var receivedIds: seq[array[32, byte]]
    var receivedAsks: seq[StorageAsk]
    proc onRequest(id: array[32, byte], ask: StorageAsk) =
      receivedIds.add(id)
      receivedAsks.add(ask)
    let subscription = await market.subscribeRequests(onRequest)
    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    check receivedIds == @[request.id]
    check receivedAsks == @[request.ask]
    await subscription.unsubscribe()

  test "supports fulfilling of requests":
    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    await market.fulfillRequest(request.id, proof)

  test "can retrieve host that fulfilled request":
    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    check (await market.getHost(request.id)) == none Address
    await market.fulfillRequest(request.id, proof)
    check (await market.getHost(request.id)) == some accounts[0]

  test "support fulfillment subscriptions":
    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    var receivedIds: seq[array[32, byte]]
    proc onFulfillment(id: array[32, byte]) =
      receivedIds.add(id)
    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)
    await market.fulfillRequest(request.id, proof)
    check receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to fulfillmentof a certain request":
    var otherRequest = StorageRequest.example
    otherRequest.client = accounts[0]

    await token.approve(storage.address, request.ask.reward)
    discard await market.requestStorage(request)
    await token.approve(storage.address, otherrequest.ask.reward)
    discard await market.requestStorage(otherRequest)

    var receivedIds: seq[array[32, byte]]
    proc onFulfillment(id: array[32, byte]) =
      receivedIds.add(id)

    let subscription = await market.subscribeFulfillment(request.id, onFulfillment)

    await market.fulfillRequest(request.id, proof)
    await market.fulfillRequest(otherRequest.id, proof)

    check receivedIds == @[request.id]

    await subscription.unsubscribe()
