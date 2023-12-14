## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/sequtils

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../../units
import ../../errors

import ./codexmerkletree

const MaxMerkleTreeSize = 100.MiBs.uint
const MaxMerkleProofSize = 1.MiBs.uint

proc encode*(self: CodexMerkleTree): seq[byte] =
  var pb = initProtoBuffer(maxSize = MaxMerkleTreeSize)
  pb.write(1, self.mcodec.uint64)
  pb.write(2, self.digestSize.uint64)
  pb.write(3, self.leavesCount.uint64)
  var nodesPb = initProtoBuffer(maxSize = MaxMerkleTreeSize)
  for node in self.nodes:
    nodesPb.write(1, node)
  nodesPb.finish()
  pb.write(4, nodesPb)

  pb.finish
  pb.buffer

proc decode*(_: type CodexMerkleTree, data: seq[byte]): ?!CodexMerkleTree =
  var pb = initProtoBuffer(data, maxSize = MaxMerkleTreeSize)
  var mcodecCode: uint64
  var digestSize: uint64
  var leavesCount: uint64
  discard ? pb.getField(1, mcodecCode).mapFailure
  discard ? pb.getField(2, digestSize).mapFailure
  discard ? pb.getField(3, leavesCount).mapFailure

  let mcodec = MultiCodec.codec(mcodecCode.int)
  if mcodec == InvalidMultiCodec:
    return failure("Invalid MultiCodec code " & $mcodecCode)

  var
    nodesBuff: seq[seq[byte]]
    nodes: seq[ByteHash]

  if ? pb.getRepeatedField(4, nodesBuff).mapFailure:
    for nodeBuff in nodesBuff:
      var node: ByteHash
      let nodePb = initProtoBuffer(nodeBuff)
      discard ? nodePb.getField(1, node).mapFailure
      nodes.add node

  let tree = ? CodexMerkleTree.fromNodes(mcodec, digestSize, leavesCount, nodesBuffer)
  success(tree)

proc encode*(self: CodexMerkleProof): seq[byte] =
  var pb = initProtoBuffer(maxSize = MaxMerkleProofSize)
  pb.write(1, self.mcodec.uint64)
  pb.write(2, self.digestSize.uint64)
  pb.write(3, self.index.uint64)
  var nodesPb = initProtoBuffer(maxSize = MaxMerkleTreeSize)
  for node in self.path:
    nodesPb.write(1, node)
  nodesPb.finish()
  pb.write(4, nodesPb)
  pb.finish
  pb.buffer

proc decode*(_: type CodexMerkleProof, data: seq[byte]): ?!CodexMerkleProof =
  var pb = initProtoBuffer(data, maxSize = MaxMerkleProofSize)
  var mcodecCode: uint64
  var digestSize: uint64
  var index: uint64
  discard ? pb.getField(1, mcodecCode).mapFailure

  let mcodec = MultiCodec.codec(mcodecCode.int)
  if mcodec == InvalidMultiCodec:
    return failure("Invalid MultiCodec code " & $mcodecCode)

  discard ? pb.getField(2, digestSize).mapFailure
  discard ? pb.getField(3, index).mapFailure

  var
    nodesBuff: seq[seq[byte]]
    nodes: seq[ByteHash]

  if ? pb.getRepeatedField(4, nodesBuff).mapFailure:
    for nodeBuff in nodesBuff:
      var node: ByteHash
      let nodePb = initProtoBuffer(nodeBuff)
      discard ? nodePb.getField(1, node).mapFailure
      nodes.add node

  let
    proof = ? CodexMerkleProof.init(mcodec, index.int, nodes)

  success(proof)
