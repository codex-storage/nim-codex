## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/math
import std/bitops
import std/sugar

import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

type
  MerkleHash* = MultiHash
  MerkleTree* = object
    leavesCount: int
    nodes: seq[MerkleHash]
  MerkleProof* = object
    index: int
    path: seq[MerkleHash]

# Tree constructed from leaves H0..H2 is
#  
#     H5=H(H3 & H4)
#    /              \
#   H3=H(H0 & H1)   H4=H(H2 & H2)
#  /      \        /
# H0=H(A) H1=H(B) H2=H(C)
# |       |       |
# A       B       C
#
# Proof for B is [H0, H4]

func calcTreeHeight(leavesCount: int): int =
  if isPowerOfTwo(leavesCount): 
    fastLog2(leavesCount) + 1
  else:
    fastLog2(leavesCount) + 2

func getLowHigh(leavesCount, level: int): (int, int) =
  var width = leavesCount
  var low = 0
  for _ in 0..<level:
    low += width
    width = (width + 1) div 2
  
  (low, low + width - 1)

func getLowHigh(self: MerkleTree, level: int): (int, int) =
  getLowHigh(self.leavesCount, level)

func getTotalSize(leavesCount: int): int =
  let height = calcTreeHeight(leavesCount)
  getLowHigh(leavesCount, height - 1)[1] + 1

proc getWidth(self: MerkleTree, level: int): int =
  let (low, high) = self.getLowHigh(level)
  high - low + 1

func getChildren(self: MerkleTree, level, i: int): (MerkleHash, MerkleHash) =
  let (low, high) = self.getLowHigh(level - 1)
  let leftIdx = low + 2 * i
  let rightIdx = min(leftIdx + 1, high)

  (self.nodes[leftIdx], self.nodes[rightIdx])

func getSibling(self: MerkleTree, level, i: int): MerkleHash =
  let (low, high) = self.getLowHigh(level)
  if i mod 2 == 0:
    self.nodes[min(low + i + 1, high)]
  else:
    self.nodes[low + i - 1]

proc setNode(self: var MerkleTree, level, i: int, value: MerkleHash): void =
  let (low, _) = self.getLowHigh(level)
  self.nodes[low + i] = value

proc root*(self: MerkleTree): MerkleHash =
  self.nodes[^1]

proc len*(self: MerkleTree): int =
  self.nodes.len

proc leaves*(self: MerkleTree): seq[MerkleHash] =
  self.nodes[0..<self.leavesCount]

proc nodes*(self: MerkleTree): seq[MerkleHash] =
  self.nodes

proc height*(self: MerkleTree): int =
  calcTreeHeight(self.leavesCount)

proc `$`*(self: MerkleTree): string =
  result &= "leavesCount: " & $self.leavesCount
  result &= "\nnodes: " & $self.nodes

proc getProof*(self: MerkleTree, index: int): ?!MerkleProof =
  if index > self.leaves.high or index < 0:
    return failure("Index " & $index & " out of range [0.." & $self.leaves.high & "]" )

  var path = newSeq[MerkleHash](self.height - 1)
  for level in 0..<path.len:
    let i = index div (1 shl level)
    path[level] = self.getSibling(level, i)

  success(MerkleProof(index: index, path: path))

proc initTreeFromLeaves(leaves: openArray[MerkleHash]): ?!MerkleTree =
  without mcodec =? leaves.?[0].?mcodec and
          digestSize =? leaves.?[0].?size:
    return failure("At least one leaf is required")

  if not leaves.allIt(it.mcodec == mcodec):
    return failure("All leaves must use the same codec")

  let totalSize = getTotalSize(leaves.len)
  var tree = MerkleTree(leavesCount: leaves.len, nodes: newSeq[MerkleHash](totalSize))

  var buf = newSeq[byte](digestSize * 2)
  proc combine(l, r: MerkleHash): ?!MerkleHash =
    copyMem(addr buf[0], unsafeAddr l.data.buffer[0], digestSize)
    copyMem(addr buf[digestSize], unsafeAddr r.data.buffer[0], digestSize)

    MultiHash.digest($mcodec, buf).mapErr(
      c => newException(CatchableError, "Error calculating hash using codec " & $mcodec & ": " & $c)
    )

  # copy leaves
  for i in 0..<tree.getWidth(0):
    tree.setNode(0, i, leaves[i])

  # calculate intermediate nodes
  for level in 1..<tree.height:
    for i in 0..<tree.getWidth(level):
      let (left, right) = tree.getChildren(level, i)
      
      without mhash =? combine(left, right), error:
        return failure(error)
      tree.setNode(level, i, mhash)

  success(tree)

func init*(
  T: type MerkleTree,
  root: MerkleHash,
  leavesCount: int
): MerkleTree =
  let totalSize = getTotalSize(leavesCount)
  var nodes = newSeq[MerkleHash](totalSize)
  nodes[^1] = root
  MerkleTree(nodes: nodes, leavesCount: leavesCount)

proc init*(
  T: type MerkleTree,
  leaves: openArray[MerkleHash]
): ?!MerkleTree =
  initTreeFromLeaves(leaves)

proc index*(self: MerkleProof): int =
  self.index

proc path*(self: MerkleProof): seq[MerkleHash] =
  self.path

proc `$`*(self: MerkleProof): string =
  result &= "index: " & $self.index
  result &= "\npath: " & $self.path

func `==`*(a, b: MerkleProof): bool =
  (a.index == b.index) and (a.path == b.path)

proc init*(
  T: type MerkleProof,
  index: int,
  path: seq[MerkleHash]
): MerkleProof =
  MerkleProof(index: index, path: path)
