import std/json
import pkg/chronos
import pkg/ethers/testing
import codex/contracts
import codex/contracts/testtoken
import codex/storageproofs
import ../ethertest
import ./examples
import ./matchers
import ./time

ethersuite "Storage contracts":
  let proof = seq[byte].example

  var client, host: Signer
  var storage: Storage
  var token: TestToken
  var collateralAmount: UInt256
  var periodicity: Periodicity
  var request: StorageRequest
  var slotId: SlotId

  proc switchAccount(account: Signer) =
    storage = storage.connect(account)
    token = token.connect(account)

  setup:
    client = provider.getSigner(accounts[0])
    host = provider.getSigner(accounts[1])

    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
    token = TestToken.new(!deployment.address(TestToken), provider.getSigner())

    await token.mint(await client.getAddress(), 1_000_000_000.u256)
    await token.mint(await host.getAddress(), 1000_000_000.u256)

    collateralAmount = await storage.collateralAmount()
    periodicity = Periodicity(seconds: await storage.proofPeriod())

    request = StorageRequest.example
    request.client = await client.getAddress()

    switchAccount(client)
    await token.approve(storage.address, request.price)
    await storage.requestStorage(request)
    switchAccount(host)
    await token.approve(storage.address, collateralAmount)
    await storage.deposit(collateralAmount)
    await storage.fillSlot(request.id, 0.u256, proof)
    slotId = request.slotId(0.u256)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await storage.isProofRequired(slotId)) and
      (await storage.getPointer(slotId)) < 250
    ):
      await provider.advanceTime(periodicity.seconds)

  test "accept storage proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    await storage.submitProof(slotId, proof)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    switchAccount(client)
    await storage.markProofAsMissing(slotId, missingPeriod)

  test "can be payed out at the end":
    switchAccount(host)
    await provider.advanceTimeTo(await storage.proofEnd(slotId))
    await storage.payoutSlot(request.id, 0.u256)

  test "cannot mark proofs missing for cancelled request":
    await provider.advanceTimeTo(request.expiry + 1)
    switchAccount(client)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    check:
      revertsWith "Slot not accepting proofs":
        await storage.markProofAsMissing(slotId, missingPeriod)
