import std/unittest
import std/sequtils
import std/sugar

import pkg/poseidon2
import pkg/poseidon2/io
import pkg/questionable/results
import pkg/results
import pkg/stew/byteutils
import pkg/stew/arrayops
import constantine/math/arithmetic
import constantine/math/io/io_bigints
import pkg/constantine/math/io/io_fields
import pkg/constantine/platforms/abstractions

import pkg/codex/merkletree

import ./generictreetests

const
  data =
    [
      "0000000000000000000000000000001".toBytes,
      "0000000000000000000000000000002".toBytes,
      "0000000000000000000000000000003".toBytes,
      "0000000000000000000000000000004".toBytes,
      "0000000000000000000000000000005".toBytes,
      "0000000000000000000000000000006".toBytes,
      "0000000000000000000000000000007".toBytes,
      "0000000000000000000000000000008".toBytes,
      "0000000000000000000000000000009".toBytes,
      "0000000000000000000000000000010".toBytes,
    ]

suite "Test CodexMerkleTree":
  var
    expectedLeaves: seq[Poseidon2Hash]

  setup:
    expectedLeaves = toSeq( data.concat().elements(Poseidon2Hash) )

  test "Should fail init tree from empty leaves":
    check:
      Poseidon2MerkleTree.init( leaves = newSeq[Poseidon2Hash](0) ).isErr

  test "Init tree from poseidon2 leaves":
    let
      tree = Poseidon2MerkleTree.init( leaves = expectedLeaves ).tryGet

    check:
      tree.leaves == expectedLeaves

  test "Init tree from byte leaves":
    let
      tree = Poseidon2MerkleTree.init(
        leaves = data.mapIt(
          array[31, byte].initCopyFrom( it )
        )).tryGet

    check:
      tree.leaves == expectedLeaves

  test "Should build from nodes":
    let
      tree = Poseidon2MerkleTree.init(leaves = expectedLeaves).tryGet
      fromNodes = Poseidon2MerkleTree.fromNodes(
        nodes = toSeq(tree.nodes),
        nleaves = tree.leavesCount).tryGet

    check:
      tree == fromNodes

let
  compressor = proc(
    x, y: Poseidon2Hash,
    key: PoseidonKeysEnum): Poseidon2Hash {.noSideEffect.} =
    compress(x, y, key.toKey)

  makeTree = proc(data: seq[Poseidon2Hash]): Poseidon2MerkleTree =
    Poseidon2MerkleTree.init(leaves = data).tryGet

checkGenericTree(
  "Poseidon2MerkleTree",
  toSeq( data.concat().elements(Poseidon2Hash) ),
  zero,
  compressor,
  makeTree)