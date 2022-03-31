import pkg/chronos
import dagger/contracts
import dagger/contracts/testtoken
import ./ethertest
import ./examples
import ./time

ethersuite "On-Chain Market":

  var market: OnChainMarket
  var storage: Storage
  var token: TestToken
  var request: StorageRequest
  var offer: StorageOffer

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
    offer = StorageOffer.example
    request.client = accounts[0]
    offer.host = accounts[0]
    offer.requestId = request.id
    offer.price = request.maxPrice

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = storage.connect(provider)
    expect AssertionError:
      discard OnChainMarket.new(storageWithoutSigner)

  test "supports storage requests":
    await token.approve(storage.address, request.maxPrice)
    check (await market.requestStorage(request)) == request

  test "sets client address when submitting storage request":
    var requestWithoutClient = request
    requestWithoutClient.client = Address.default
    await token.approve(storage.address, request.maxPrice)
    let submitted = await market.requestStorage(requestWithoutClient)
    check submitted.client == accounts[0]

  test "supports request subscriptions":
    var received: seq[StorageRequest]
    proc onRequest(request: StorageRequest) =
      received.add(request)
    let subscription = await market.subscribeRequests(onRequest)
    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    check received == @[request]
    await subscription.unsubscribe()

  test "supports storage offers":
    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    check (await market.offerStorage(offer)) == offer

  test "sets host address when submitting storage offer":
    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    var offerWithoutHost = offer
    offerWithoutHost.host = Address.default
    let submitted = await market.offerStorage(offerWithoutHost)
    check submitted.host == accounts[0]

  test "supports offer subscriptions":
    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    var received: seq[StorageOffer]
    proc onOffer(offer: StorageOffer) =
      received.add(offer)
    let subscription = await market.subscribeOffers(request.id, onOffer)
    discard await market.offerStorage(offer)
    check received == @[offer]
    await subscription.unsubscribe()

  test "subscribes only to offers for a certain request":
    var otherRequest = StorageRequest.example
    var otherOffer = StorageOffer.example
    otherRequest.client = accounts[0]
    otherOffer.host = accounts[0]
    otherOffer.requestId = otherRequest.id
    otherOffer.price = otherRequest.maxPrice

    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    await token.approve(storage.address, otherRequest.maxPrice)
    discard await market.requestStorage(otherRequest)

    var submitted: seq[StorageOffer]
    proc onOffer(offer: StorageOffer) =
      submitted.add(offer)

    let subscription = await market.subscribeOffers(request.id, onOffer)

    discard await market.offerStorage(offer)
    discard await market.offerStorage(otherOffer)

    check submitted == @[offer]

    await subscription.unsubscribe()

  test "supports selection of an offer":
    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    discard await market.offerStorage(offer)

    var selected: seq[array[32, byte]]
    proc onSelect(offerId: array[32, byte]) =
      selected.add(offerId)
    let subscription = await market.subscribeSelection(request.id, onSelect)

    await market.selectOffer(offer.id)

    check selected == @[offer.id]

    await subscription.unsubscribe()

  test "subscribes only to selection for a certain request":
    var otherRequest = StorageRequest.example
    var otherOffer = StorageOffer.example
    otherRequest.client = accounts[0]
    otherOffer.host = accounts[0]
    otherOffer.requestId = otherRequest.id
    otherOffer.price = otherRequest.maxPrice

    await token.approve(storage.address, request.maxPrice)
    discard await market.requestStorage(request)
    discard await market.offerStorage(offer)
    await token.approve(storage.address, otherRequest.maxPrice)
    discard await market.requestStorage(otherRequest)
    discard await market.offerStorage(otherOffer)

    var selected: seq[array[32, byte]]
    proc onSelect(offerId: array[32, byte]) =
      selected.add(offerId)

    let subscription = await market.subscribeSelection(request.id, onSelect)

    await market.selectOffer(offer.id)
    await market.selectOffer(otherOffer.id)

    check selected == @[offer.id]

    await subscription.unsubscribe()

  test "can retrieve current block time":
    let latestBlock = !await provider.getBlock(BlockTag.latest)
    check (await market.getTime()) == latestBlock.timestamp

  test "supports waiting for expiry of a request or offer":
    let pollInterval = 200.milliseconds
    market.pollInterval = pollInterval

    proc waitForPoll {.async.} =
      await sleepAsync(pollInterval * 2)

    let future = market.waitUntil(request.expiry)
    check not future.completed
    await provider.advanceTimeTo(request.expiry - 1)
    await waitForPoll()
    check not future.completed
    await provider.advanceTimeTo(request.expiry)
    await waitForPoll()
    check future.completed
