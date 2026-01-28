import std/sequtils
import std/times

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/libp2p

import pkg/codex/codextypes
import pkg/codex/merkletree
import pkg/codex/utils/digest

import pkg/taskpools

import ./helpers
import ../../asynctest

# TODO: Generalize to other hashes

const
  data = [
    "00000000000000000000000000000001".toBytes,
    "00000000000000000000000000000002".toBytes,
    "00000000000000000000000000000003".toBytes,
    "00000000000000000000000000000004".toBytes,
    "00000000000000000000000000000005".toBytes,
    "00000000000000000000000000000006".toBytes,
    "00000000000000000000000000000007".toBytes,
    "00000000000000000000000000000008".toBytes,
    "00000000000000000000000000000009".toBytes,
    "00000000000000000000000000000010".toBytes,
  ]
  sha256 = Sha256HashCodec

suite "Test StorageMerkleTree":
  test "Cannot init tree without any multihash leaves":
    check:
      StorageMerkleTree.init(leaves = newSeq[MultiHash]()).isErr
      StorageMerkleTree.init(leaves = newSeq[MultiHash]()).isErr

  test "Cannot init tree without any cid leaves":
    check:
      StorageMerkleTree.init(leaves = newSeq[Cid]()).isErr
      StorageMerkleTree.init(leaves = newSeq[Cid]()).isErr

  test "Cannot init tree without any byte leaves":
    check:
      StorageMerkleTree.init(sha256, leaves = newSeq[ByteHash]()).isErr
      StorageMerkleTree.init(sha256, leaves = newSeq[ByteHash]()).isErr

  test "Should build tree from multihash leaves":
    var
      expectedLeaves = data.mapIt(MultiHash.digest($sha256, it).tryGet())
      tree = StorageMerkleTree.init(leaves = expectedLeaves)

    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.digestBytes)
      tree.get().mcodec == sha256

  test "Should build tree from multihash leaves asynchronously":
    var tp = Taskpool.new(numThreads = 2)
    defer:
      tp.shutdown()

    let expectedLeaves = data.mapIt(MultiHash.digest($sha256, it).tryGet())

    let tree = (await StorageMerkleTree.init(tp, leaves = expectedLeaves))
    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.digestBytes)
      tree.get().mcodec == sha256

  test "Should build tree from cid leaves":
    var expectedLeaves = data.mapIt(
      Cid.init(CidVersion.CIDv1, BlockCodec, MultiHash.digest($sha256, it).tryGet).tryGet
    )

    let tree = StorageMerkleTree.init(leaves = expectedLeaves)

    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.mhash.tryGet.digestBytes)
      tree.get().mcodec == sha256

  test "Should build tree from cid leaves asynchronously":
    var tp = Taskpool.new(numThreads = 2)
    defer:
      tp.shutdown()

    let expectedLeaves = data.mapIt(
      Cid.init(CidVersion.CIDv1, BlockCodec, MultiHash.digest($sha256, it).tryGet).tryGet
    )

    let tree = (await StorageMerkleTree.init(tp, leaves = expectedLeaves))

    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.mhash.tryGet.digestBytes)
      tree.get().mcodec == sha256

  test "Should build tree the same tree sync and async":
    var tp = Taskpool.new(numThreads = 2)
    defer:
      tp.shutdown()

    let expectedLeaves = data.mapIt(
      Cid.init(CidVersion.CIDv1, BlockCodec, MultiHash.digest($sha256, it).tryGet).tryGet
    )

    let
      atree = (await StorageMerkleTree.init(tp, leaves = expectedLeaves))
      stree = StorageMerkleTree.init(leaves = expectedLeaves)

    check:
      toSeq(atree.get().nodes) == toSeq(stree.get().nodes)
      atree.get().root == stree.get().root

    # Single-leaf trees have their root separately computed
    let
      atree1 = (await StorageMerkleTree.init(tp, leaves = expectedLeaves[0 .. 0]))
      stree1 = StorageMerkleTree.init(leaves = expectedLeaves[0 .. 0])

    check:
      toSeq(atree.get().nodes) == toSeq(stree.get().nodes)
      atree.get().root == stree.get().root

  test "Should build from raw digestbytes (should not hash leaves)":
    let tree = StorageMerkleTree.init(sha256, leaves = data).tryGet

    check:
      tree.mcodec == sha256
      tree.leaves == data

  test "Should build from raw digestbytes (should not hash leaves) asynchronously":
    var tp = Taskpool.new(numThreads = 2)
    defer:
      tp.shutdown()

    let tree = (await StorageMerkleTree.init(tp, sha256, leaves = @data))

    check:
      tree.isOk
      tree.get().mcodec == sha256
      tree.get().leaves == data

  test "Should build from nodes":
    let
      tree = StorageMerkleTree.init(sha256, leaves = data).tryGet
      fromNodes = StorageMerkleTree.fromNodes(
        nodes = toSeq(tree.nodes), nleaves = tree.leavesCount
      ).tryGet

    check:
      tree.mcodec == sha256
      tree == fromNodes

let
  digestSize = sha256.digestSize.get
  zero: seq[byte] = newSeq[byte](digestSize)
  compress = proc(x, y: seq[byte], key: ByteTreeKey): seq[byte] =
    compress(x, y, key, sha256).tryGet

  makeTree = proc(data: seq[seq[byte]]): StorageMerkleTree =
    StorageMerkleTree.init(sha256, leaves = data).tryGet
