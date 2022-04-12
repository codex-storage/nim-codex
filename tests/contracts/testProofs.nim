import ./ethertest
import dagger/contracts
import ./examples
import ./time

ethersuite "On-Chain Proofs":

  var proofs: OnChainProofs
  var storage: Storage

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider)
    proofs = OnChainProofs.new(storage)

  test "can retrieve proof periodicity":
    let periodicity = await proofs.periodicity()
    let periodLength = await storage.proofPeriod()
    check periodicity.seconds == periodLength

  test "supports waiting until next period":
    let periodicity = await proofs.periodicity()
    let currentPeriod = await proofs.getCurrentPeriod()

    let pollInterval = 200.milliseconds
    proofs.pollInterval = pollInterval

    proc waitForPoll {.async.} =
      await sleepAsync(pollInterval * 2)

    let future = proofs.waitUntilPeriod(currentPeriod + 1)

    check not future.completed

    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    await waitForPoll()

    check future.completed

  test "supports checking whether proof is required now":
    check (await proofs.isProofRequired(ContractId.example)) == false

  test "supports checking whether proof is required soon":
    check (await proofs.willProofBeRequired(ContractId.example)) == false

  test "retrieves proof end time":
    check (await proofs.getProofEnd(ContractId.example)) == 0.u256
