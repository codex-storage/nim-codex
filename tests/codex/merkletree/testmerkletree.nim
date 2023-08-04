import std/unittest
import std/bitops
import std/random
import std/sequtils
import pkg/libp2p
import codex/merkletree/merkletree
import ../helpers
import pkg/questionable/results

checksuite "merkletree":
  const sha256 = multiCodec("sha2-256")
  const sha512 = multiCodec("sha2-512")

  proc randomHash(codec: MultiCodec = sha256): MerkleHash =
    var data: array[0..31, byte]
    for i in 0..31:
      data[i] = rand(uint8)
    return MultiHash.digest($codec, data).tryGet()

  proc combine(a, b: MerkleHash, codec: MultiCodec = sha256): MerkleHash =
    var buf = newSeq[byte](a.size + b.size)
    for i in 0..<a.size:
      buf[i] = a.data.buffer[i]
    for i in 0..<b.size:
      buf[i + a.size] = b.data.buffer[i]
    return MultiHash.digest($codec, buf).tryGet()

  var
    leaves: array[0..10, MerkleHash]

  setup:
    for i in 0..leaves.high:
      leaves[i] = randomHash()

  test "tree with one leaf has expected root":
    let tree = MerkleTree.new(leaves[0..0]).tryGet()

    check:
      tree.leaves == leaves[0..0]
      tree.root == leaves[0]
      tree.len == 1

  test "tree with two leaves has expected root":
    let
      expectedRoot = combine(leaves[0], leaves[1])

    let tree = MerkleTree.new(leaves[0..1]).tryGet()

    check:
      tree.leaves == leaves[0..1]
      tree.len == 3
      tree.root == expectedRoot

  test "tree with three leaves has expected root":
    let
      expectedRoot = combine(combine(leaves[0], leaves[1]), combine(leaves[2], leaves[2]))

    let tree = MerkleTree.new(leaves[0..2]).tryGet()

    check:
      tree.leaves == leaves[0..2]
      tree.len == 6
      tree.root == expectedRoot

  test "tree with two leaves provides expected proofs":
    let tree = MerkleTree.new(leaves[0..1]).tryGet()

    let expectedProofs = [
      MerkleProof(index: 0, path: @[leaves[1]]),
      MerkleProof(index: 1, path: @[leaves[0]]),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
  
  test "tree with three leaves provides expected proofs":
    let tree = MerkleTree.new(leaves[0..2]).tryGet()

    let expectedProofs = [
      MerkleProof(index: 0, path: @[leaves[1], combine(leaves[2], leaves[2])]),
      MerkleProof(index: 1, path: @[leaves[0], combine(leaves[2], leaves[2])]),
      MerkleProof(index: 2, path: @[leaves[2], combine(leaves[0], leaves[1])]),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
      tree.getProof(2).tryGet() == expectedProofs[2]

  test "getProof fails for index out of bounds":
    let tree = MerkleTree.new(leaves[0..3]).tryGet()

    check:
      isErr(tree.getProof(-1))
      isErr(tree.getProof(4))

  test "can create MerkleTree directly from root hash":
    let tree = MerkleTree.new(leaves[0], 1)

    check:
      tree.root == leaves[0]

  test "cannot create MerkleTree from leaves with different codec":
    let res = MerkleTree.new(@[randomHash(sha256), randomHash(sha512)])

    check:
      isErr(res)
