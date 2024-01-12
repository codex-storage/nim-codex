import std/sequtils

import pkg/questionable/results
import pkg/constantine/math/arithmetic
import pkg/constantine/math/io/io_fields
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/stores/cachestore
import pkg/codex/chunker
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore
import pkg/codex/indexingstrategy

import pkg/codex/proof/datasamplerstarter
import pkg/codex/slots/converters
import pkg/codex/utils/poseidon2digest
import pkg/codex/slots/builder

import ../helpers
import ../examples
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test datasampler starter":
  var env: ProvingTestEnvironment

  setup:
    env = await createProvingTestEnvironment()

  teardown:
    reset(env)

  proc run(): Future[DataSamplerStarter] {.async.} =
    (await startDataSampler(env.localStore, env.manifest, env.slot)).tryGet()

  test "Returns dataset slot index":
    let start = await run()

    check:
      start.datasetSlotIndex == datasetSlotIndex.uint64

  test "Returns dataset-to-slot proof":
    let
      start = await run()
      expectedProof = env.datasetToSlotTree.getProof(datasetSlotIndex).tryGet()

    check:
      start.datasetToSlotProof == expectedProof

  test "Returns slot tree CID":
    let
      start = await run()
      expectedCid = env.slotTree.root().tryGet().toSlotCid().tryGet()

    check:
      start.slotTreeCid == expectedCid

  test "Fails when manifest is not a verifiable manifest":
    # Basic manifest:
    env.manifest = Manifest.new(
      treeCid = env.manifest.treeCid,
      blockSize = bytesPerBlock.NBytes,
      datasetSize = env.manifest.datasetSize)

    let start = await startDataSampler(env.localStore, env.manifest, env.slot)

    check:
      start.isErr
      start.error.msg == "Can only create DataSampler using verifiable manifests."

  test "Fails when reconstructed dataset root does not match manifest root":
    var newSlotRoots = env.manifest.slotRoots
    newSlotRoots[0] = toF(999).toSlotCid().tryGet()

    env.manifest = Manifest.new(
      manifest = env.manifest,
      verifyRoot = env.manifest.verifyRoot,
      slotRoots = newSlotRoots
    ).tryGet()

    let start = await startDataSampler(env.localStore, env.manifest, env.slot)

    check:
      start.isErr
      start.error.msg == "Reconstructed dataset root does not match manifest dataset root."

  test "Starter will recreate Slot tree when not present in local store":
    # Remove proofs from the local store
    var expectedProofs = newSeq[(Cid, CodexProof)]()
    for i in 0 ..< numberOfSlotBlocks:
      expectedProofs.add((await env.localStore.getCidAndProof(env.slotRootCid, i)).tryGet())
      discard (await env.localStore.delBlock(env.slotRootCid, i))

    discard await run()

    for i in 0 ..< numberOfSlotBlocks:
      let
        expectedProof = expectedProofs[i]
        actualProof = (await env.localStore.getCidAndProof(env.slotRootCid, i)).tryGet()

      check:
        expectedProof == actualProof

  test "Recreation of Slot tree fails when recreated slot root is different from manifest slot root":
    # Remove proofs from the local store
    for i in 0 ..< numberOfSlotBlocks:
      discard (await env.localStore.delBlock(env.manifest.slotRoots[0], i))

    # Replace second slotRoot with a copy of the first. Recreate the verify root to match.
    let
      newSlotRoots = newSeq[Cid]() & env.manifest.slotRoots[0] & env.manifest.slotRoots[0]
      leafs = newSlotRoots.mapIt(it.fromSlotCid().tryGet())
      rootsPadLeafs = newSeqWith(totalNumberOfSlots.nextPowerOfTwoPad, Poseidon2Zero)
      newVerifyRoot = Poseidon2Tree.init(leafs & rootsPadLeafs).tryGet()
        .root().tryGet()
        .toProvingCid().tryGet()

    env.manifest = Manifest.new(
      manifest = env.manifest,
      verifyRoot = newVerifyRoot,
      slotRoots = newSlotRoots
    ).tryGet()

    let start = await startDataSampler(env.localStore, env.manifest, env.slot)

    check:
      start.isErr
      start.error.msg == "Reconstructed slot root does not match manifest slot root."
