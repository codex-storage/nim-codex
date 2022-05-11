import dagger/contracts
import ../ethertest
import ./examples
import ./time

ethersuite "On-Chain Proofs":

  let contractId = ContractId.example
  let proof = seq[byte].example

  var proofs: OnChainProofs
  var storage: Storage

  setup:
    let deployment = deployment()
    storage = Storage.new(!deployment.address(Storage), provider.getSigner())
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
    check (await proofs.isProofRequired(contractId)) == false

  test "supports checking whether proof is required soon":
    check (await proofs.willProofBeRequired(contractId)) == false

  test "retrieves proof end time":
    check (await proofs.getProofEnd(contractId)) == 0.u256

  test "submits proofs":
    await proofs.submitProof(contractId, proof)

  test "supports proof submission subscriptions":
    var receivedIds: seq[ContractId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: ContractId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await proofs.subscribeProofSubmission(onProofSubmission)

    await proofs.submitProof(contractId, proof)

    check receivedIds == @[contractId]
    check receivedProofs == @[proof]

    await subscription.unsubscribe()
