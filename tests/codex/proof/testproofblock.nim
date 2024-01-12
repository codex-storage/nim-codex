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
import pkg/codex/proof/proofblock
import pkg/codex/utils/poseidon2digest
import pkg/codex/blocktype as bt

import ../helpers
import ../examples
import ../merkletree/helpers
import ./provingtestenv

asyncchecksuite "Test proof block":
  let
    emptyBlock = Cid.example.emptyBlock.tryGet()
    exampleBlock = bt.Block.example
  var padding: ProofPadding

  setup:
    let env = await createProvingTestEnvironment()
    padding = ProofPadding.new(env.manifest, DefaultCellSize).tryGet()

  teardown:
    reset(padding)

  test "can get root for empty block":
    let
      expectedEmptyRoot = padding.blockEmptyDigest
      proofBlock = ProofBlock.new(padding, emptyBlock, DefaultCellSize).tryGet()

    check:
      proofBlock.root.tryGet() == expectedEmptyRoot

  test "can get root of block tree":
    let
      expectedRoot = Poseidon2Tree.digest(exampleBlock.data & padding.blockPadBytes, DefaultCellSize.int).tryGet()
      proofBlock = ProofBlock.new(padding, exampleBlock, DefaultCellSize).tryGet()
      actual = proofBlock.root.tryGet()

    check:
      actual == expectedRoot

  test "fails to get proof for empty block":
    let
      expectedEmptyRoot = padding.blockEmptyDigest
      proofBlock = ProofBlock.new(padding, emptyBlock, DefaultCellSize).tryGet()
      proof = proofBlock.proof(0)

    check:
      proof.isErr
      proof.error.msg == "Can't get proof from empty block"

  test "can get proof from block tree":
    let
      tree = Poseidon2Tree.digestTree(exampleBlock.data & padding.blockPadBytes, DefaultCellSize.int).tryGet()
      expectedProof = tree.getProof(0).tryGet()
      proofBlock = ProofBlock.new(padding, exampleBlock, DefaultCellSize).tryGet()

    check:
      proofBlock.proof(0).tryGet() == expectedProof
