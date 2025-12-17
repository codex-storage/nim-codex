import std/sequtils

import pkg/poseidon2
import pkg/poseidon2/io
import pkg/questionable/results
import pkg/results
import pkg/stew/byteutils
import pkg/stew/arrayops

import pkg/codex/merkletree
import pkg/taskpools

import ./generictreetests
import ./helpers
import ../../asynctest

const data = [
  "0000000000000000000000000000001".toBytes,
  "0000000000000000000000000000002".toBytes,
  "0000000000000000000000000000003".toBytes,
  "0000000000000000000000000000004".toBytes,
  "0000000000000000000000000000005".toBytes,
  "0000000000000000000000000000006".toBytes,
  "0000000000000000000000000000007".toBytes,
  "0000000000000000000000000000008".toBytes,
  "0000000000000000000000000000009".toBytes,
    # note one less to account for padding of field elements
]

suite "Test Poseidon2Tree":
  var expectedLeaves: seq[Poseidon2Hash]

  setup:
    expectedLeaves = toSeq(data.concat().elements(Poseidon2Hash))

  test "Should fail init tree from empty leaves":
    check:
      Poseidon2Tree.init(leaves = newSeq[Poseidon2Hash](0)).isErr

  test "Build tree from poseidon2 leaves":
    var taskpool = Taskpool.new(numThreads = 2)
    let tree = (await Poseidon2Tree.init(taskpool, leaves = expectedLeaves)).tryGet()

    check:
      tree.leaves == expectedLeaves

  test "Build tree from byte leaves":
    let tree = Poseidon2Tree.init(
      leaves = expectedLeaves.mapIt(array[31, byte].initCopyFrom(it.toBytes))
    ).tryGet

    check:
      tree.leaves == expectedLeaves

  test "Build tree from nodes":
    let
      tree = Poseidon2Tree.init(leaves = expectedLeaves).tryGet
      fromNodes = Poseidon2Tree.fromNodes(
        nodes = toSeq(tree.nodes), nleaves = tree.leavesCount
      ).tryGet

    check:
      tree == fromNodes

  test "Build poseidon2 tree from poseidon2 leaves asynchronously":
    var tp = Taskpool.new()
    defer:
      tp.shutdown()

    let tree = (await Poseidon2Tree.init(tp, leaves = expectedLeaves)).tryGet()
    check:
      tree.leaves == expectedLeaves

  test "Build poseidon2 tree from byte leaves asynchronously":
    var tp = Taskpool.new()
    defer:
      tp.shutdown()

    let tree = (
      await Poseidon2Tree.init(
        tp, leaves = expectedLeaves.mapIt(array[31, byte].initCopyFrom(it.toBytes))
      )
    ).tryGet()

    check:
      tree.leaves == expectedLeaves

let
  compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): Poseidon2Hash {.noSideEffect.} =
    compress(x, y, key.toKey)

  makeTree = proc(data: seq[Poseidon2Hash]): Poseidon2Tree =
    Poseidon2Tree.init(leaves = data).tryGet

testGenericTree(
  "Poseidon2Tree",
  toSeq(data.concat().elements(Poseidon2Hash)),
  zero,
  compressor,
  makeTree,
)
