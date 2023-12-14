import std/unittest
import std/sequtils
import std/tables

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/nimcrypto/sha2

import pkg/codex/merkletree

import ../helpers
import ./generictreetests

# TODO: Generalize to other hashes

const
  data =
    [
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
  sha256 = multiCodec("sha2-256")

checksuite "merkletree":
  test "Cannot init tree without any multihash leaves":
    check:
      CodexMerkleTree.init(leaves = newSeq[MultiHash]()).isErr

  test "Cannot init tree without any cid leaves":
    check:
      CodexMerkleTree.init(leaves = newSeq[Cid]()).isErr

  test "Cannot init tree without any byte leaves":
    check:
      CodexMerkleTree.init(sha256, leaves =  newSeq[ByteHash]()).isErr

  test "Should build tree from multihash leaves":
    var
      expectedLeaves = data.mapIt(  MultiHash.digest($sha256, it).tryGet() )

    var tree = CodexMerkleTree.init(leaves = expectedLeaves)
    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt( it.bytes )
      tree.get().mcodec == sha256

  test "Should build tree from cid leaves":
    var
      expectedLeaves = data.mapIt(  Cid.init(
        CidVersion.CIDv1, BlockCodec, MultiHash.digest($sha256, it).tryGet ).tryGet )

    let
      tree = CodexMerkleTree.init(leaves = expectedLeaves)

    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt( it.mhash.tryGet.bytes )
      tree.get().mcodec == sha256

  test "Should build from raw bytes (should not hash leaves)":
    let
      tree = CodexMerkleTree.init(sha256, leaves = data).tryGet

    check:
      tree.mcodec == sha256
      tree.leaves == data

let
  mhash = sha256.getMhash().tryGet
  zero: seq[byte] = newSeq[byte](mhash.size)
  compress = proc(x, y: seq[byte], key: ByteTreeKey): seq[byte] =
    compress(x, y, key, mhash).tryGet

  makeTree = proc(data: seq[seq[byte]]): CodexMerkleTree =
    CodexMerkleTree.init(sha256, leaves = data).tryGet

checkGenericTree(
  "CodexMerkleTree",
  @data,
  zero,
  compress,
  makeTree)
