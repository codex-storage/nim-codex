import pkg/chronos
import pkg/nimcrypto
import dagger/contracts
import dagger/contracts/testtoken
import ./ethertest
import ./examples

ethersuite "Storage contracts":

  let (request, bid) = (StorageRequest, StorageBid).example

  var client, host: Signer
  var storage: Storage
  var token: TestToken
  var stakeAmount: UInt256

  setup:
    let deployment = deployment()
    client = provider.getSigner(accounts[0])
    host = provider.getSigner(accounts[1])
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())
    await token.connect(client).mint(await client.getAddress(), 1000.u256)
    await token.connect(host).mint(await host.getAddress(), 1000.u256)
    stakeAmount = await storage.stakeAmount()

  proc newContract(): Future[array[32, byte]] {.async.} =
    await token.connect(host).approve(Address(storage.address), stakeAmount)
    await storage.connect(host).increaseStake(stakeAmount)
    await token.connect(client).approve(Address(storage.address), bid.price)
    let requestHash = hashRequest(request)
    let bidHash = hashBid(bid)
    let requestSignature = await client.signMessage(@requestHash)
    let bidSignature = await host.signMessage(@bidHash)
    await storage.connect(client).newContract(
      request,
      bid,
      await host.getAddress(),
      requestSignature,
      bidSignature
    )
    let id = bidHash
    return id

  proc mineUntilProofRequired(id: array[32, byte]): Future[UInt256] {.async.} =
    var blocknumber: UInt256
    var done = false
    while not done:
      blocknumber = await provider.getBlockNumber()
      done = await storage.isProofRequired(id, blocknumber)
      if not done:
        discard await provider.send("evm_mine")
    return blocknumber

  proc mineUntilProofTimeout(id: array[32, byte]) {.async.} =
    let timeout = await storage.proofTimeout(id)
    for _ in 0..<timeout.truncate(int):
      discard await provider.send("evm_mine")

  proc mineUntilEnd(id: array[32, byte]) {.async.} =
    let proofEnd = await storage.proofEnd(id)
    while (await provider.getBlockNumber()) < proofEnd:
      discard await provider.send("evm_mine")

  test "can be created":
    let id = await newContract()
    check (await storage.duration(id)) == request.duration
    check (await storage.size(id)) == request.size
    check (await storage.contentHash(id)) == request.contentHash
    check (await storage.proofPeriod(id)) == request.proofPeriod
    check (await storage.proofTimeout(id)) == request.proofTimeout
    check (await storage.price(id)) == bid.price
    check (await storage.host(id)) == (await host.getAddress())

  test "can be started by the host":
    let id = await newContract()
    await storage.connect(host).startContract(id)
    let proofEnd = await storage.proofEnd(id)
    check proofEnd > 0

  test "accept storage proofs":
    let id = await newContract()
    await storage.connect(host).startContract(id)
    let blocknumber = await mineUntilProofRequired(id)
    await storage.connect(host).submitProof(id, blocknumber, true)

  test "marks missing proofs":
    let id = await newContract()
    await storage.connect(host).startContract(id)
    let blocknumber = await mineUntilProofRequired(id)
    await mineUntilProofTimeout(id)
    await storage.connect(client).markProofAsMissing(id, blocknumber)

  test "can be finished":
    let id = await newContract()
    await storage.connect(host).startContract(id)
    await mineUntilEnd(id)
    await storage.connect(host).finishContract(id)
