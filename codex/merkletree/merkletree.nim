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
import std/algorithm

import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/nimcrypto/sha2
import pkg/libp2p/[cid, multicodec, multihash, vbuffer]
import pkg/stew/byteutils

import ../errors

logScope:
  topics = "codex merkletree"

type
  MerkleTree* = object
    mcodec: MultiCodec
    digestSize: Natural
    leavesCount: Natural
    nodesBuffer*: seq[byte]
  MerkleProof* = object
    mcodec: MultiCodec
    digestSize: Natural
    index: Natural
    nodesBuffer*: seq[byte]
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

proc digestFn(mcodec: MultiCodec, dst: var openArray[byte], dstPos: int, data: openArray[byte]): ?!void =
  var mhash = ? MultiHash.digest($mcodec, data).mapFailure
  if (dstPos + mhash.size) > dst.len:
    return failure("Not enough space in a destination buffer")
  dst[dstPos..<dstPos + mhash.size] = mhash.data.buffer[mhash.dpos..<mhash.dpos + mhash.size]
  success()

###########################################################
# MerkleTreeBuilder
###########################################################

proc init*(
  T: type MerkleTreeBuilder,
  mcodec: MultiCodec = multiCodec("sha2-256")
): ?!MerkleTreeBuilder =
  let mhash = ? MultiHash.digest($mcodec, "".toBytes).mapFailure
  success(MerkleTreeBuilder(mcodec: mcodec, digestSize: mhash.size, buffer: newSeq[byte]()))

proc addDataBlock*(self: var MerkleTreeBuilder, dataBlock: openArray[byte]): ?!void =
  ## Hashes the data block and adds the result of hashing to a buffer
  ## 
  let oldLen = self.buffer.len
  self.buffer.setLen(oldLen + self.digestSize)
  digestFn(self.mcodec, self.buffer, oldLen, dataBlock)

proc addLeaf*(self: var MerkleTreeBuilder, leaf: MultiHash): ?!void =
  if leaf.mcodec != self.mcodec or leaf.size != self.digestSize:
    return failure("Expected mcodec to be " & $self.mcodec & " and digest size to be " & 
      $self.digestSize & " but was " & $leaf.mcodec & " and " & $leaf.size)
  
  let oldLen = self.buffer.len
  self.buffer.setLen(oldLen + self.digestSize)
  self.buffer[oldLen..<oldLen + self.digestSize] = leaf.data.buffer[leaf.dpos..<leaf.dpos + self.digestSize]
  success()

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
  tree.nodesBuffer[0..<leavesCount * digestSize] = self.buffer[0..<leavesCount * digestSize]

  # calculate intermediate nodes
  var zero = newSeq[byte](digestSize)
  var one = newSeq[byte](digestSize)
  one[^1] = 0x01

  var 
    concatBuf = newSeq[byte](2 * digestSize)
    prevLevel = levels[0]
  for level in levels[1..^1]:
    for i in 0..<level.width:
      let parentIndex = level.offset + i
      let leftChildIndex = prevLevel.offset + 2 * i
      let rightChildIndex = leftChildIndex + 1

      concatBuf[0..<digestSize] = tree.nodesBuffer[leftChildIndex * digestSize..<(leftChildIndex + 1) * digestSize]

      var dummyValue = if prevLevel.index == 0: zero else: one

      if rightChildIndex < prevLevel.offset + prevLevel.width:
        concatBuf[digestSize..^1] = tree.nodesBuffer[rightChildIndex * digestSize..<(rightChildIndex + 1) * digestSize]
      else:
        concatBuf[digestSize..^1] = dummyValue

      ? digestFn(mcodec, tree.nodesBuffer, parentIndex * digestSize, concatBuf)
    prevLevel = level

  return success(tree)

###########################################################
# MerkleTree
###########################################################

proc nodeBufferToMultiHash(self: (MerkleTree | MerkleProof), index: int): MultiHash =
  var buf = newSeq[byte](self.digestSize)
  let offset = index * self.digestSize
  buf[0..^1] = self.nodesBuffer[offset..<(offset + self.digestSize)]

  {.noSideEffect.}:
    without mhash =? MultiHash.init($self.mcodec, buf).mapFailure, errx:
      error "Error converting bytes to hash", msg = errx.msg
  mhash

proc len*(self: (MerkleTree | MerkleProof)): Natural =
  self.nodesBuffer.len div self.digestSize

proc nodes*(self: (MerkleTree | MerkleProof)): seq[MultiHash] {.noSideEffect.} =
  toSeq(0..<self.len).map(i => self.nodeBufferToMultiHash(i))

proc mcodec*(self: (MerkleTree | MerkleProof)): MultiCodec =
  self.mcodec

proc digestSize*(self: (MerkleTree | MerkleProof)): Natural = 
  self.digestSize

proc root*(self: MerkleTree): MultiHash =
  let rootIndex = self.len - 1
  self.nodeBufferToMultiHash(rootIndex)

proc rootCid*(self: MerkleTree, version = CIDv1, dataCodec = multiCodec("raw")): ?!Cid =
  Cid.init(version, dataCodec, self.root).mapFailure

iterator leaves*(self: MerkleTree): MultiHash =
  for i in 0..<self.leavesCount:
    yield self.nodeBufferToMultiHash(i)

iterator leavesCids*(self: MerkleTree, version = CIDv1, dataCodec = multiCodec("raw")): ?!Cid =
  for leaf in self.leaves:
    yield Cid.init(version, dataCodec, leaf).mapFailure

proc leavesCount*(self: MerkleTree): Natural =
  self.leavesCount

proc getLeaf*(self: MerkleTree, index: Natural): ?!MultiHash =
  if index >= self.leavesCount:
    return failure("Index " & $index & " out of range [0.." & $(self.leavesCount - 1) & "]" )
  
  success(self.nodeBufferToMultiHash(index))

proc getLeafCid*(self: MerkleTree, index: Natural, version = CIDv1, dataCodec = multiCodec("raw")): ?!Cid =
  let leaf = ? self.getLeaf(index)
  Cid.init(version, dataCodec, leaf).mapFailure

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
    let lr = index shr level.index
    let siblingIndex = if lr mod 2 == 0:
      level.offset + lr + 1
    else:
      level.offset + lr - 1

    var dummyValue = if level.index == 0: zero else: one

    if siblingIndex < level.offset + level.width:
      proofNodesBuffer[level.index * self.digestSize..<(level.index + 1) * self.digestSize] = 
        self.nodesBuffer[siblingIndex * self.digestSize..<(siblingIndex + 1) * self.digestSize]
    else:
      proofNodesBuffer[level.index * self.digestSize..<(level.index + 1) * self.digestSize] = dummyValue

  success(MerkleProof(mcodec: self.mcodec, digestSize: self.digestSize, index: index, nodesBuffer: proofNodesBuffer))

proc `$`*(self: MerkleTree): string {.noSideEffect.} =
  "mcodec:" & $self.mcodec &
    ", digestSize: " & $self.digestSize &
    ", leavesCount: " & $self.leavesCount &
    ", nodes: " & $self.nodes

proc `==`*(a, b: MerkleTree): bool =
  (a.mcodec == b.mcodec) and
  (a.digestSize == b.digestSize) and
  (a.leavesCount == b.leavesCount) and
    (a.nodesBuffer == b.nodesBuffer)

proc init*(
  T: type MerkleTree,
  mcodec: MultiCodec,
  digestSize: Natural,
  leavesCount: Natural,
  nodesBuffer: seq[byte]
): ?!MerkleTree =
  let levels = computeLevels(leavesCount)
  let totalNodes = levels[^1].offset + 1
  if totalNodes * digestSize == nodesBuffer.len:
    success(
      MerkleTree(
        mcodec: mcodec, 
        digestSize: digestSize, 
        leavesCount: leavesCount, 
        nodesBuffer: nodesBuffer
      )
    )
  else:
    failure("Expected nodesBuffer len to be " & $(totalNodes * digestSize) & " but was " & $nodesBuffer.len)

proc init*(
  T: type MerkleTree,
  leaves: openArray[MultiHash]
): ?!MerkleTree =
  without leaf =? leaves.?[0]:
    return failure("At least one leaf is required")
  
  var builder = ? MerkleTreeBuilder.init(mcodec = leaf.mcodec)

  for l in leaves:
    let res = builder.addLeaf(l)
    if res.isErr:
      return failure(res.error)
  
  builder.build()

proc init*(
  T: type MerkleTree,
  cids: openArray[Cid]
): ?!MerkleTree =
  var leaves = newSeq[MultiHash]()
  
  for cid in cids:
    let res = cid.mhash.mapFailure
    if res.isErr:
      return failure(res.error)
    else:
      leaves.add(res.value)

  MerkleTree.init(leaves)

###########################################################
# MerkleProof
###########################################################

proc verifyLeaf*(self: MerkleProof, leaf: MultiHash, treeRoot: MultiHash): ?!bool =
  if leaf.mcodec != self.mcodec:
    return failure("Leaf mcodec was " & $leaf.mcodec & ", but " & $self.mcodec & " expected")

  if leaf.mcodec != self.mcodec:
    return failure("Tree root mcodec was " & $treeRoot.mcodec & ", but " & $treeRoot.mcodec & " expected")

  var digestBuf = newSeq[byte](self.digestSize)
  digestBuf[0..^1] = leaf.data.buffer[leaf.dpos..<(leaf.dpos + self.digestSize)]

  let proofLen = self.nodesBuffer.len div self.digestSize
  var concatBuf = newSeq[byte](2 * self.digestSize)
  for i in 0..<proofLen:
    let offset = i * self.digestSize
    let lr = self.index shr i
    if lr mod 2 == 0:
      concatBuf[0..^1] = digestBuf & self.nodesBuffer[offset..<(offset + self.digestSize)]
    else:
      concatBuf[0..^1] = self.nodesBuffer[offset..<(offset + self.digestSize)] & digestBuf
    ? digestFn(self.mcodec, digestBuf, 0, concatBuf)
  
  let computedRoot = ? MultiHash.init(self.mcodec, digestBuf).mapFailure

  success(computedRoot == treeRoot)


proc verifyDataBlock*(self: MerkleProof, dataBlock: openArray[byte], treeRoot: MultiHash): ?!bool =
  var digestBuf = newSeq[byte](self.digestSize)
  ? digestFn(self.mcodec, digestBuf, 0, dataBlock)

  let leaf = ? MultiHash.init(self.mcodec, digestBuf).mapFailure

  self.verifyLeaf(leaf, treeRoot)

proc index*(self: MerkleProof): Natural =
  self.index

proc `$`*(self: MerkleProof): string =
  "mcodec:" & $self.mcodec &
    ", digestSize: " & $self.digestSize &
    ", index: " & $self.index &
    ", nodes: " & $self.nodes

func `==`*(a, b: MerkleProof): bool =
  (a.index == b.index) and 
    (a.mcodec == b.mcodec) and 
    (a.digestSize == b.digestSize) and
    (a.nodesBuffer == b.nodesBuffer)

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
    nodesBuffer[nodeIndex * digestSize..<(nodeIndex + 1) * digestSize] = node.data.buffer[node.dpos..<node.dpos + digestSize]
  
  success(MerkleProof(mcodec: mcodec, digestSize: digestSize, index: index, nodesBuffer: nodesBuffer))

func init*(
  T: type MerkleProof,
  mcodec: MultiCodec,
  digestSize: Natural,
  index: Natural,
  nodesBuffer: seq[byte]
): ?!MerkleProof =

  if nodesBuffer.len mod digestSize != 0:
    return failure("nodesBuffer len is not a multiple of digestSize")

  let treeHeight = (nodesBuffer.len div digestSize) + 1
  let maxLeavesCount = 1 shl treeHeight
  if index < maxLeavesCount:
    return success(
      MerkleProof(
        mcodec: mcodec,
        digestSize: digestSize,
        index: index,
        nodesBuffer: nodesBuffer
      )
    )
  else:
    return failure("index higher than max leaves count")
