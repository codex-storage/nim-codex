import std/unittest
import std/bitops
import std/random
import std/sequtils
import pkg/libp2p
import codex/merkletree/merkletree
import ../helpers

checksuite "merkletree":
  let mcodec = multiCodec("sha2-256")

  var
    builder: MerkleTreeBuilder
    leaf1: MerkleHash
    leaf2: MerkleHash

  proc createRandomHash(): MerkleHash =
    var data: array[0..31, byte]
    for i in 0..31:
      data[i] = rand(uint8)
    return MultiHash.digest($mcodec, data).tryGet()

  proc combine(a: MerkleHash, b: MerkleHash): MerkleHash =
    #todo: hash these together please
    return createRandomHash()

  setup:
    builder = MerkleTreeBuilder()
    leaf1 = createRandomHash()
    leaf2 = createRandomHash()

  test "can build tree with one leaf":
    check:
      not isErr(builder.addLeaf(leaf1))

    let tree = builder.build()
    echo "tree is" & $tree

    check:
      tree.numberOfLeafs == 1
      tree.len == 1
      tree.rootHash == leaf1

  test "fails when adding leaf with different hash codec":
    let
      differentCodec = multiCodec("raw")

    var data: array[0..31, byte]
    for i in 0..31:
      data[i] = rand(uint8)

    let differentLeaf = MultiHash.digest($differentCodec, data).tryGet()

    check:
      not isErr(builder.addLeaf(leaf1))
      isErr(builder.addLeaf(differentLeaf))

  test "tree with two leaves has expected root hash":
    let
      expectedRootHash = combine(leaf1, leaf2)

    check:
      not isErr(builder.addLeaf(leaf1))
      not isErr(builder.addLeaf(leaf2))

    let tree = builder.build()
    echo "tree is" & $tree

    check:
      tree.numberOfLeafs == 2
      tree.len == 3
      tree.rootHash == expectedRootHash
