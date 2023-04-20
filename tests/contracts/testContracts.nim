import std/json
import pkg/chronos
import pkg/ethers/testing
import pkg/ethers/erc20
import codex/contracts
import ../ethertest
import ./examples
import ./time
import ./deployment

ethersuite "Marketplace contracts":
  let proof = exampleProof()

  var client, host: Signer
  var marketplace: Marketplace
  var token: Erc20Token
  var periodicity: Periodicity
  var request: StorageRequest
  var slotId: SlotId

  proc switchAccount(account: Signer) =
    marketplace = marketplace.connect(account)
    token = token.connect(account)

  setup:
    client = provider.getSigner(accounts[0])
    host = provider.getSigner(accounts[1])

    marketplace = Marketplace.new(marketAddress(), provider.getSigner())

    let tokenAddress = await marketplace.token()
    token = Erc20Token.new(tokenAddress, provider.getSigner())

    let config = await marketplace.config()
    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = await client.getAddress()

    switchAccount(client)
    await token.approve(marketplace.address, request.price)
    await marketplace.requestStorage(request)
    switchAccount(host)
    await token.approve(marketplace.address, request.ask.collateral)
    await marketplace.fillSlot(request.id, 0.u256, proof)
    slotId = request.slotId(0.u256)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    ):
      await provider.advanceTime(periodicity.seconds)

  proc startContract() {.async.} =
    for slotIndex in 1..<request.ask.slots:
      await token.approve(marketplace.address, request.ask.collateral)
      await marketplace.fillSlot(request.id, slotIndex.u256, proof)

  test "accept marketplace proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    await marketplace.submitProof(slotId, proof)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    switchAccount(client)
    await marketplace.markProofAsMissing(slotId, missingPeriod)

  test "can be paid out at the end":
    switchAccount(host)
    let address = await host.getAddress()
    await startContract()
    let requestEnd = await marketplace.requestEnd(request.id)
    await provider.advanceTimeTo(requestEnd.u256)
    let startBalance = await token.balanceOf(address)
    await marketplace.freeSlot(slotId)
    let endBalance = await token.balanceOf(address)
    check endBalance == (startBalance + request.ask.duration * request.ask.reward + request.ask.collateral)

  test "cannot mark proofs missing for cancelled request":
    await provider.advanceTimeTo(request.expiry + 1)
    switchAccount(client)
    let missingPeriod = periodicity.periodOf(await provider.currentTime())
    await provider.advanceTime(periodicity.seconds)
    check await marketplace
      .markProofAsMissing(slotId, missingPeriod)
      .reverts("Slot not accepting proofs")
