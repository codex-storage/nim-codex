import std/sequtils

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/libp2p
import pkg/taskpools
import pkg/chronos

import pkg/asynctest/chronos/unittest2

export unittest2

import pkg/codex/codextypes
import pkg/codex/merkletree
import pkg/codex/utils/digest

import ./helpers

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

suite "Test CodexTree":
  var taskpool: Taskpool

  setup:
    taskpool = Taskpool.new()

  teardown:
    taskpool.shutdown()

  test "Should build tree from multihash leaves asyncronosly":
    var t = await CodexTree.init(taskpool, sha256, leaves = data)
    var tree = t.tryGet()
    check:
      tree.isOk
      tree.get().leaves == data
      tree.get().mcodec == sha256
