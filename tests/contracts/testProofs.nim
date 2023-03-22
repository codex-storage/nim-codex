import codex/contracts
import ../ethertest
import ./examples

ethersuite "On-Chain Proofs":

  let contractId = SlotId.example
  let proof = exampleProof()

  var proofs: OnChainProofs
  var marketplace: Marketplace

  setup:
    let deployment = deployment()
    marketplace = Marketplace.new(!deployment.address(Marketplace), provider.getSigner())
    proofs = OnChainProofs.new(marketplace)

  test "can retrieve proof periodicity":
    let periodicity = await proofs.periodicity()
    let config = await marketplace.config()
    let periodLength = config.proofs.period
    check periodicity.seconds == periodLength

  test "supports checking whether proof is required now":
    check (await proofs.isProofRequired(contractId)) == false

  test "supports checking whether proof is required soon":
    check (await proofs.willProofBeRequired(contractId)) == false

  test "retrieves correct slot state when request is unknown":
    check (await proofs.slotState(SlotId.example)) == SlotState.Free

  test "submits proofs":
    await proofs.submitProof(contractId, proof)

  test "supports proof submission subscriptions":
    var receivedIds: seq[SlotId]
    var receivedProofs: seq[seq[byte]]

    proc onProofSubmission(id: SlotId, proof: seq[byte]) =
      receivedIds.add(id)
      receivedProofs.add(proof)

    let subscription = await proofs.subscribeProofSubmission(onProofSubmission)

    await proofs.submitProof(contractId, proof)

    check receivedIds == @[contractId]
    check receivedProofs == @[proof]

    await subscription.unsubscribe()

  test "proof not required when slot is empty":
    check not await proofs.isProofRequired(contractId)

  test "proof will not be required when slot is empty":
    check not await proofs.willProofBeRequired(contractId)
