import ./ethertest
import dagger/contracts
import ./examples
import ./time

ethersuite "On-Chain Proof Timing":

  var timing: OnChainProofTiming
  var storage: Storage

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider)
    timing = OnChainProofTiming.new(storage)

  test "can retrieve proof periodicity":
    let periodicity = await timing.periodicity()
    let periodLength = await storage.proofPeriod()
    check periodicity.seconds == periodLength

  test "supports waiting until next period":
    let periodicity = await timing.periodicity()
    let currentPeriod = periodicity.periodOf(await provider.currentTime())

    let pollInterval = 200.milliseconds
    timing.pollInterval = pollInterval

    proc waitForPoll {.async.} =
      await sleepAsync(pollInterval * 2)

    let future = timing.waitUntilNextPeriod()

    check not future.completed

    await provider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    await waitForPoll()

    check future.completed

  test "supports checking whether proof is required now":
    check (await timing.isProofRequired(ContractId.example)) == false

  test "supports checking whether proof is required soon":
    check (await timing.willProofBeRequired(ContractId.example)) == false

  test "retrieves proof end time":
    check (await timing.getProofEnd(ContractId.example)) == 0.u256
