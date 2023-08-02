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
    leaf3: MerkleHash
    leaf4: MerkleHash
    node12: MerkleHash
    node34: MerkleHash
    root: MerkleHash

  proc createRandomHash(): MerkleHash =
    var data: array[0..31, byte]
    for i in 0..31:
      data[i] = rand(uint8)
    return MultiHash.digest($mcodec, data).tryGet()

  proc combine(a: MerkleHash, b: MerkleHash): MerkleHash =
    #todo: hash these together please
    return createRandomHash()

  proc createMerkleTree(leaves: seq[MerkleHash]): MerkleTree =
    let b = MerkleTreeBuilder()
    for leaf in leaves:
      check:
        not isErr(b.addLeaf(leaf))
    return b.build()

  proc createRandomMerkleTree(numberOfLeafs: int): MerkleTree =
    var leaves = newSeq[MerkleHash]()
    for i in 0..numberOfLeafs:
      leaves.add(createRandomHash())
    return createMerkleTree(leaves)

  proc assertExampleTreeExpectedPaths(tree: MerkleTree) =
    let expectedPaths = @[
        @[leaf1, node12, root],
        @[leaf2, node12, root],
        @[leaf3, node34, root],
        @[leaf4, node34, root]
      ]

    for i in 0..3:
      let expectedPath = expectedPaths[i]
      let proof = tree.getProof(i).tryGet()
      check:
        proof.len == expectedPath.len
      for x in 0..proof.len:
        check:
          proof[x] == expectedPath[x]

  setup:
    builder = MerkleTreeBuilder()
    leaf1 = createRandomHash()
    leaf2 = createRandomHash()
    leaf3 = createRandomHash()
    leaf4 = createRandomHash()
    node12 = combine(leaf1, leaf2)
    node34 = combine(leaf3, leaf4)
    root = combine(node12, node34)

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
      differentCodec = multiCodec("identity")

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

  test "tree can access leaves by index":
    let tree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])

    check:
      tree.numberOfLeafs == 4
      tree.len == 10
      tree.getLeaf(0).tryGet() == leaf1
      tree.getLeaf(1).tryGet() == leaf2
      tree.getLeaf(2).tryGet() == leaf3
      tree.getLeaf(3).tryGet() == leaf4

  test "getLeaf fails for index out of bounds":
    let tree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])

    check:
      isErr(tree.getLeaf(-1))
      isErr(tree.getLeaf(4))

  test "tree can provide merkle proof by index":
    let tree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])

    assertExampleTreeExpectedPaths(tree)

  test "getProof fails for index out of bounds":
    let tree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])

    check:
      isErr(tree.getProof(-1))
      isErr(tree.getProof(4))

  test "can create MerkleTree directly from root hash":
    let tree = MerkleTree.new(root)

    check:
      # these dimenions may need adjusting:
      tree.numberOfLeafs == 0
      tree.len == 1
      # do we need to pass any of the tree dimensions to the constructor for any reason?

      tree.rootHash == root

  test "can recreate a MerkleTree from MerkleProofs":
    let
      sourceTree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])
      targetTree = MerkleTree.new(root)

    for i in 0..3:
      let proof = sourceTree.getProof(i).tryGet()
      check:
        not isErr(targetTree.addProof(i, proof))

    check:
      targetTree.numberOfLeafs == 4
      targetTree.len == 10
      targetTree.rootHash == root

    assertExampleTreeExpectedPaths(targetTree)

  test "addProof will reject proofs from foreign trees":
    let
      sourceTree = createMerkleTree(@[leaf1, leaf2, leaf3, leaf4])
      foreignTree = createRandomMerkleTree(4)
      targetTree = MerkleTree.new(root)

    for i in 0..3:
      check:
        isErr(targetTree.addProof(i, foreignTree.getProof(i).tryGet()))
        not isErr(targetTree.addProof(i, sourceTree.getProof(i).tryGet()))

    assertExampleTreeExpectedPaths(targetTree)
