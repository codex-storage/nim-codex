## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/math
import std/bitops
import std/sequtils
import std/sugar

import pkg/questionable/results
import pkg/nimcrypto/sha2
import pkg/libp2p/[multicodec, multihash, vbuffer]

import ../errors

type
  MerkleTree* = object
    mcodec: MultiCodec
    digestSize: Natural
    leavesCount: Natural
    nodesBuffer: seq[byte]
  MerkleProof* = object
    mcodec: MultiCodec
    digestSize: Natural
    index: Natural
    nodesBuffer: seq[byte]
  MerkleTreeBuilder* = object
    mcodec: MultiCodec
    digestSize: Natural
    buffer: seq[byte]

###########################################################
# Helper functions
###########################################################

func computeTreeHeight(leavesCount: int): int =
  if isPowerOfTwo(leavesCount): 
    fastLog2(leavesCount) + 1
  else:
    fastLog2(leavesCount) + 2

func computeLevels(leavesCount: int): seq[tuple[offset: int, width: int, index: int]] =
  let height = computeTreeHeight(leavesCount)
  var levels = newSeq[tuple[offset: int, width: int, index: int]](height)

  levels[0].offset = 0
  levels[0].width = leavesCount
  levels[0].index = 0
  for i in 1..<height:
    levels[i].offset = levels[i - 1].offset + levels[i - 1].width
    levels[i].width = (levels[i - 1].width + 1) div 2
    levels[i].index = i
  levels

proc digestFn(mcodec: MultiCodec, output: pointer, data: openArray[byte]): ?!void =
  var mhash = ? MultiHash.digest($mcodec, data).mapFailure
  copyMem(output, addr mhash.data.buffer[mhash.dpos], mhash.size)
  success()

###########################################################
# MerkleTreeBuilder
###########################################################

proc init*(
  T: type MerkleTreeBuilder,
  mcodec: MultiCodec
): ?!MerkleTreeBuilder =
  let mhash = ? MultiHash.digest($mcodec, "".toBytes).mapFailure
  success(MerkleTreeBuilder(mcodec: mcodec, digestSize: mhash.size, buffer: newSeq[byte]()))

proc addDataBlock*(self: var MerkleTreeBuilder, dataBlock: openArray[byte]): ?!void =
  ## Hashes the data block and adds the result of hashing to a buffer
  ## 
  let oldLen = self.buffer.len
  self.buffer.setLen(oldLen + self.digestSize)
  digestFn(self.mcodec, addr self.buffer[oldLen], dataBlock)

proc build*(self: MerkleTreeBuilder): ?!MerkleTree =
  ## Builds a tree from previously added data blocks
  ## 
  ## Tree built from data blocks A, B and C is
  ##        H5=H(H3 & H4)
  ##      /            \
  ##    H3=H(H0 & H1)   H4=H(H2 & 0x00)
  ##   /    \          /
  ## H0=H(A) H1=H(B) H2=H(C)
  ## |       |       |
  ## A       B       C
  ##
  ## Memory layout is [H0, H1, H2, H3, H4, H5]
  ##
  let
    mcodec = self.mcodec 
    digestSize = self.digestSize
    leavesCount = self.buffer.len div self.digestSize

  if leavesCount == 0:
    return failure("At least one data block is required")

  let levels = computeLevels(leavesCount)
  let totalNodes = levels[^1].offset + 1
  
  var tree = MerkleTree(mcodec: mcodec, digestSize: digestSize, leavesCount: leavesCount, nodesBuffer: newSeq[byte](totalNodes * digestSize))

  # copy leaves
  copyMem(addr tree.nodesBuffer[0], unsafeAddr self.buffer[0], leavesCount * digestSize)

  # calculate intermediate nodes
  var zero = newSeq[byte](self.digestSize)
  var one = newSeq[byte](self.digestSize)
  one[^1] = 0x01

  var concatBuf = newSeq[byte](2 * digestSize)
  var prevLevel = levels[0]
  for level in levels[1..^1]:
    for i in 0..<level.width:
      let parentIndex = level.offset + i
      let leftChildIndex = prevLevel.offset + 2 * i
      let rightChildIndex = leftChildIndex + 1

      copyMem(addr concatBuf[0], addr tree.nodesBuffer[leftChildIndex * digestSize], digestSize)

      var dummyValue = if prevLevel.index == 0: zero else: one

      if rightChildIndex < prevLevel.offset + prevLevel.width:
        copyMem(addr concatBuf[digestSize], addr tree.nodesBuffer[rightChildIndex * digestSize], digestSize)
      else:
        copyMem(addr concatBuf[digestSize], addr dummyValue[0], digestSize)

      ? digestFn(mcodec, addr tree.nodesBuffer[parentIndex * digestSize], concatBuf)
    prevLevel = level

  return success(tree)

###########################################################
# MerkleTree
###########################################################

proc nodeBufferToMultiHash(self: (MerkleTree | MerkleProof), index: int): MultiHash =
  var buf = newSeq[byte](self.digestSize)
  copyMem(addr buf[0], unsafeAddr self.nodesBuffer[index * self.digestSize], self.digestSize)
  without mhash =? MultiHash.init($self.mcodec, buf).mapFailure, error:
    raise error
  mhash

proc len*(self: (MerkleTree | MerkleProof)): Natural =
  self.nodesBuffer.len div self.digestSize

proc nodes*(self: (MerkleTree | MerkleProof)): seq[MultiHash] =
  toSeq(0..<self.len).map(i => self.nodeBufferToMultiHash(i))

proc root*(self: MerkleTree): MultiHash =
  let rootIndex = self.len - 1
  self.nodeBufferToMultiHash(rootIndex)

proc leaves*(self: MerkleTree): seq[MultiHash] =
  toSeq(0..<self.leavesCount).map(i => self.nodeBufferToMultiHash(i))

proc height*(self: MerkleTree): Natural =
  computeTreeHeight(self.leavesCount)

proc getProof*(self: MerkleTree, index: Natural): ?!MerkleProof =
  ## Extracts proof from a tree for a given index
  ## 
  ## Given a tree built from data blocks A, B and C
  ##         H5
  ##      /     \
  ##    H3       H4
  ##   /  \     /
  ## H0    H1 H2
  ## |     |  |
  ## A     B  C
  ##
  ## Proofs of inclusion (index and path) are
  ## - 0,[H1, H4] for data block A
  ## - 1,[H0, H4] for data block B
  ## - 2,[0x00, H3] for data block C
  ## 
  if index >= self.leavesCount:
    return failure("Index " & $index & " out of range [0.." & $(self.leavesCount - 1) & "]" )

  var zero = newSeq[byte](self.digestSize)
  var one = newSeq[byte](self.digestSize)
  one[^1] = 0x01

  let levels = computeLevels(self.leavesCount)
  var proofNodesBuffer = newSeq[byte]((levels.len - 1) * self.digestSize)
  for level in levels[0..^2]:
    let i = index div (1 shl level.index)
    let siblingIndex = if i mod 2 == 0:
      level.offset + i + 1
    else:
      level.offset + i - 1

    var dummyValue = if level.index == 0: zero else: one

    if siblingIndex < level.offset + level.width:
      copyMem(addr proofNodesBuffer[level.index * self.digestSize], unsafeAddr self.nodesBuffer[siblingIndex * self.digestSize], self.digestSize)
    else:
      copyMem(addr proofNodesBuffer[level.index * self.digestSize], addr dummyValue[0], self.digestSize)

      # path[levelIndex] = zeroHash

  success(MerkleProof(mcodec: self.mcodec, digestSize: self.digestSize, index: index, nodesBuffer: proofNodesBuffer))

proc `$`*(self: MerkleTree): string =
  "mcodec:" & $self.mcodec &
    "\nleavesCount: " & $self.leavesCount & 
    "\nnodes: " & $self.nodes

###########################################################
# MerkleProof
###########################################################

proc index*(self: MerkleProof): Natural =
  self.index

proc `$`*(self: MerkleProof): string =
  "mcodec:" & $self.mcodec &
    "\nindex: " & $self.index &
    "\nnodes: " & $self.nodes

func `==`*(a, b: MerkleProof): bool =
  (a.index == b.index) and (a.mcodec == b.mcodec) and (a.digestSize == b.digestSize) == (a.nodesBuffer == b.nodesBuffer)

proc init*(
  T: type MerkleProof,
  index: Natural,
  nodes: seq[MultiHash]
): ?!MerkleProof =
  if nodes.len == 0:
    return failure("At least one node is required")

  let
    mcodec = nodes[0].mcodec
    digestSize = nodes[0].size
    
  var nodesBuffer = newSeq[byte](nodes.len * digestSize)
  for nodeIndex, node in nodes:
    copyMem(addr nodesBuffer[nodeIndex * digestSize], unsafeAddr node.data.buffer[node.dpos], digestSize)
  
  success(MerkleProof(mcodec: mcodec, digestSize: digestSize, index: index, nodesBuffer: nodesBuffer))
