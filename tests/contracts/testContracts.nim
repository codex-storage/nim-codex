import pkg/chronos
import pkg/ethers/erc20
import codex/contracts
import ../ethertest
import ./examples
import ./time
import ./deployment

ethersuite "Marketplace contracts":
  let proof = Groth16Proof.example

  var client, host: Signer
  var marketplace: Marketplace
  var token: Erc20Token
  var periodicity: Periodicity
  var request: StorageRequest
  var slotId: SlotId
  var filledAt: UInt256

  proc expectedPayout(endTimestamp: UInt256): UInt256 =
    return (endTimestamp - filledAt) * request.ask.pricePerSlotPerSecond()

  proc switchAccount(account: Signer) =
    marketplace = marketplace.connect(account)
    token = token.connect(account)

  setup:
    client = ethProvider.getSigner(accounts[0])
    host = ethProvider.getSigner(accounts[1])

    let address = Marketplace.address(dummyVerifier = true)
    marketplace = Marketplace.new(address, ethProvider.getSigner())

    let tokenAddress = await marketplace.token()
    token = Erc20Token.new(tokenAddress, ethProvider.getSigner())

    let config = await marketplace.configuration()
    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = await client.getAddress()

    switchAccount(client)
    discard await token.approve(marketplace.address, request.totalPrice).confirm(1)
    discard await marketplace.requestStorage(request).confirm(1)
    switchAccount(host)
    discard
      await token.approve(marketplace.address, request.ask.collateralPerSlot).confirm(1)
    discard await marketplace.reserveSlot(request.id, 0.uint64).confirm(1)
    let receipt = await marketplace.fillSlot(request.id, 0.uint64, proof).confirm(1)
    filledAt = await ethProvider.blockTime(BlockTag.init(!receipt.blockNumber))
    slotId = request.slotId(0.uint64)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod =
      periodicity.periodOf((await ethProvider.currentTime()).truncate(uint64))
    await ethProvider.advanceTimeTo(periodicity.periodEnd(currentPeriod).u256)
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    )
    :
      await ethProvider.advanceTime(periodicity.seconds.u256)

  proc startContract() {.async.} =
    for slotIndex in 1 ..< request.ask.slots:
      discard await token
      .approve(marketplace.address, request.ask.collateralPerSlot)
      .confirm(1)
      discard await marketplace.reserveSlot(request.id, slotIndex.uint64).confirm(1)
      discard await marketplace.fillSlot(request.id, slotIndex.uint64, proof).confirm(1)

  test "accept marketplace proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    discard await marketplace.submitProof(slotId, proof).confirm(1)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    let missingPeriod =
      periodicity.periodOf((await ethProvider.currentTime()).truncate(uint64))
    let endOfPeriod = periodicity.periodEnd(missingPeriod)
    await ethProvider.advanceTimeTo(endOfPeriod.u256 + 1)
    switchAccount(client)
    discard await marketplace.markProofAsMissing(slotId, missingPeriod).confirm(1)

  test "can be paid out at the end":
    switchAccount(host)
    let address = await host.getAddress()
    await startContract()
    let requestEnd = await marketplace.requestEnd(request.id)
    await ethProvider.advanceTimeTo(requestEnd.u256 + 1)
    let startBalance = await token.balanceOf(address)
    discard await marketplace.freeSlot(slotId).confirm(1)
    let endBalance = await token.balanceOf(address)
    check endBalance ==
      (startBalance + expectedPayout(requestEnd.u256) + request.ask.collateralPerSlot)

  test "cannot mark proofs missing for cancelled request":
    let expiry = await marketplace.requestExpiry(request.id)
    await ethProvider.advanceTimeTo((expiry + 1).u256)
    switchAccount(client)
    let missingPeriod =
      periodicity.periodOf((await ethProvider.currentTime()).truncate(uint64))
    await ethProvider.advanceTime(periodicity.seconds.u256)
    expect Marketplace_SlotNotAcceptingProofs:
      discard await marketplace.markProofAsMissing(slotId, missingPeriod).confirm(1)
