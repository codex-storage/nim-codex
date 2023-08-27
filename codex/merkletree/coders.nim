## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ./merkletree
import ../units
import ../errors

const MaxMerkleTreeSize = 100.MiBs.uint

proc encode*(self: MerkleTree): seq[byte] =
  var pb = initProtoBuffer(maxSize = MaxMerkleTreeSize)
  pb.write(1, self.mcodec.uint64)
  pb.write(2, self.digestSize.uint64)
  pb.write(3, self.leavesCount.uint64)
  pb.write(4, self.nodesBuffer)
  pb.finish
  pb.buffer

proc decode*(_: type MerkleTree, data: seq[byte]): ?!MerkleTree =
  var pb = initProtoBuffer(data, maxSize = MaxMerkleTreeSize)
  var mcodecCode: uint64
  var digestSize: uint64
  var leavesCount: uint64
  discard ? pb.getField(1, mcodecCode).mapFailure
  discard ? pb.getField(2, digestSize).mapFailure
  discard ? pb.getField(3, leavesCount).mapFailure

  let mcodec = MultiCodec.codec(cast[int](mcodecCode))
  if mcodec == InvalidMultiCodec:
    return failure("Invalid MultiCodec code " & $cast[int](mcodec))

  var nodesBuffer = newSeq[byte]()
  discard ? pb.getField(4, nodesBuffer).mapFailure

  let tree = ? MerkleTree.init(mcodec, digestSize, leavesCount, nodesBuffer)
  success(tree)
