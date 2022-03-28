import ./ethertest
import dagger/contracts
import dagger/contracts/testtoken
import ./examples

ethersuite "On-Chain Market":

  var market: OnChainMarket
  var storage: Storage
  var token: TestToken

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.mint(accounts[0], 1000.u256)
    market = OnChainMarket.new(storage)

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = storage.connect(provider)
    expect AssertionError:
      discard OnChainMarket.new(storageWithoutSigner)

  test "supports storage requests":
    var submitted: seq[StorageRequest]
    proc onRequest(request: StorageRequest) =
      submitted.add(request)
    let subscription = await market.subscribeRequests(onRequest)
    let request = StorageRequest(
      duration: uint16.example.u256,
      size: uint32.example.u256,
      contentHash: array[32, byte].example
    )
    await market.requestStorage(request)
    check submitted.len == 1
    check submitted[0].duration == request.duration
    check submitted[0].size == request.size
    check submitted[0].contentHash == request.contentHash
    await subscription.unsubscribe()
