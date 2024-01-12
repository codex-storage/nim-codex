import std/sequtils
import std/random
import std/strutils

import pkg/questionable/results
import pkg/poseidon2/io
import pkg/poseidon2
import pkg/chronos
import pkg/asynctest
import pkg/codex/contracts/requests
import pkg/codex/contracts
import pkg/codex/merkletree
import pkg/codex/stores/cachestore
import pkg/codex/proof/proofpadding
import pkg/codex/proof/misc
import pkg/codex/proof/types
import pkg/codex/utils/poseidon2digest

import ../helpers
import ../examples
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test proof padding":
  var
    env: ProvingTestEnvironment
    padding: ProofPadding

  setup:
    env = await createProvingTestEnvironment()
    padding = ProofPadding.new(env.manifest, DefaultCellSize).tryGet()

  teardown:
    reset(env)
    reset(padding)

  test "has empty block digest":
    let
      expectedPadding = newSeq[byte]((env.manifest.blockSize.int div DefaultCellSize.int).nextPowerOfTwoPad * DefaultCellSize.int)
      expectedEmtpyDigest = Poseidon2Tree.digest(DefaultEmptyBlock & expectedPadding, DefaultCellSize.int).tryGet()

    check:
      padding.blockEmptyDigest == expectedEmtpyDigest

  test "had block padding bytes":
    let expectedPadding = newSeq[byte]((env.manifest.blockSize.int div DefaultCellSize.int).nextPowerOfTwoPad * DefaultCellSize.int)

    check:
      padding.blockPadBytes == expectedPadding

  test "has slot padding leafs":
    let expectedPadding = newSeqWith((env.manifest.blocksCount div env.manifest.numSlots).nextPowerOfTwoPad, Poseidon2Zero)

    check:
      padding.slotsPadLeafs == expectedPadding

  test "has dataset padding leafs":
    let expectedPadding = newSeqWith(env.manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)

    check:
      padding.rootsPadLeafs == expectedPadding

  test "fails when manifest is not protected":
    # Basic manifest:
    let manifest = Manifest.new(
      treeCid = env.manifest.treeCid,
      blockSize = env.manifest.blockSize,
      datasetSize = env.manifest.datasetSize)

    let padding = ProofPadding.new(manifest, DefaultCellSize)

    check:
      padding.isErr
      padding.error.msg == "Protected manifest is required."

  test "fails when number of blocks is not divisable by number of slots":
    # Protected manifest:
    let manifest = Manifest.new(
      manifest = env.manifest,
      treeCid = env.manifest.treeCid,
      datasetSize = env.manifest.datasetSize + 1,
      ecK = env.manifest.numSlots,
      ecM = 0
    )

    let padding = ProofPadding.new(manifest, DefaultCellSize)

    check:
      padding.isErr
      padding.error.msg == "Number of blocks must be divisable by number of slots."

  test "fails when block size is not divisable by cell size":
    let padding = ProofPadding.new(env.manifest, DefaultCellSize - 1)

    check:
      padding.isErr
      padding.error.msg == "Block size must be divisable by cell size."

