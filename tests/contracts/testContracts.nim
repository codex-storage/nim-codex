import std/json
import pkg/chronos
import pkg/nimcrypto
import codex/contracts
import codex/contracts/testtoken
import codex/storageproofs
import ../ethertest
import ./examples
import ./time

ethersuite "Storage contracts":
  let proof = seq[byte].example

  var client, host: Signer
  var storage: Storage
  var token: TestToken
  var collateralAmount: UInt256
  var periodicity: Periodicity
  var request: StorageRequest
  var offer: StorageOffer
  var id: array[32, byte]

  proc switchAccount(account: Signer) =
    storage = storage.connect(account)
    token = token.connect(account)

  setup:
    client = provider.getSigner(accounts[0])
    host = provider.getSigner(accounts[1])

    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())

    await token.mint(await client.getAddress(), 1000.u256)
    await token.mint(await host.getAddress(), 1000.u256)

    collateralAmount = await storage.collateralAmount()
    periodicity = Periodicity(seconds: await storage.proofPeriod())

    request = StorageRequest.example
    request.client = await client.getAddress()

    offer = StorageOffer.example
    offer.host = await host.getAddress()
    offer.requestId = request.id

    switchAccount(client)
    await token.approve(storage.address, request.ask.maxPrice)
    await storage.requestStorage(request)
    switchAccount(host)
    await token.approve(storage.address, collateralAmount)
    await storage.deposit(collateralAmount)
    await storage.fulfillRequest(request.id, proof)
    id = request.id

  proc waitUntilProofRequired(id: array[32, byte]) {.async.} =
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await storage.isProofRequired(id)) and
      (await storage.getPointer(id)) < 250
    ):
      await provider.advanceTime(periodicity.seconds)

  test "accept storage proofs":
    switchAccount(host)
    await waitUntilProofRequired(id)
    await storage.submitProof(id, proof)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(id)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    switchAccount(client)
    await storage.markProofAsMissing(id, missingPeriod)

  test "can be finished":
    switchAccount(host)
    await provider.advanceTimeTo(await storage.proofEnd(id))
    await storage.finishContract(id)
