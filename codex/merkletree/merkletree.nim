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
import std/strutils

import pkg/questionable/results
import pkg/nimcrypto/sha2

const digestSize = sha256.sizeDigest

type
  MerkleHash* = array[digestSize, byte]
  MerkleTree* = object
    leavesCount: Natural
    nodes: seq[MerkleHash]
  MerkleProof* = object
    index: Natural
    path: seq[MerkleHash]
  MerkleTreeBuilder* = object
    buffer: seq[MerkleHash]

###########################################################
# Helper functions
###########################################################

func computeTreeHeight(leavesCount: int): int =
  if isPowerOfTwo(leavesCount): 
    fastLog2(leavesCount) + 1
  else:
    fastLog2(leavesCount) + 2

func computeLevels(leavesCount: int): seq[tuple[offset: int, width: int]] =
  let height = computeTreeHeight(leavesCount)
  result = newSeq[tuple[offset: int, width: int]](height)

  result[0].offset = 0
  result[0].width = leavesCount
  for i in 1..<height:
    result[i].offset = result[i - 1].offset + result[i - 1].width
    result[i].width = (result[i - 1].width + 1) div 2

proc digestFn(data: openArray[byte], output: var MerkleHash): void =
  var digest = sha256.digest(data)
  copyMem(addr output, addr digest.data[0], digestSize)

###########################################################
# MerkleHash
###########################################################

var zeroHash: MerkleHash

proc `$`*(self: MerkleHash): string = 
  result = newStringOfCap(self.len)
  for i in 0..<self.len:
    result.add(toHex(self[i]))

###########################################################
# MerkleTreeBuilder
###########################################################

proc addDataBlock*(self: var MerkleTreeBuilder, dataBlock: openArray[byte]): void =
  ## Hashes the data block and adds the result of hashing to a buffer
  ## 
  let oldLen = self.buffer.len
  self.buffer.setLen(oldLen + 1)
  digestFn(dataBlock, self.buffer[oldLen])

proc build*(self: MerkleTreeBuilder): ?!MerkleTree =
  ## Builds a tree from previously added data blocks
  ## 
  ## Tree built from data blocks A, B and C is
  ##        H5=H(H3 & H4)
  ##      /            \
  ##    H3=H(H0 & H1)   H4=H(H2 & HZ)
  ##   /    \          /
  ## H0=H(A) H1=H(B) H2=H(C)
  ## |       |       |
  ## A       B       C
  ##
  ## where HZ=H(0x0b)
  ##
  ## Memory layout is [H0, H1, H2, H3, H4, H5]
  ##
  let leavesCount = self.buffer.len

  if leavesCount == 0:
    return failure("At least one data block is required")

  let levels = computeLevels(leavesCount)
  let totalSize = levels[^1].offset + 1
  
  var tree = MerkleTree(leavesCount: leavesCount, nodes: newSeq[MerkleHash](totalSize))

  # copy leaves
  copyMem(addr tree.nodes[0], unsafeAddr self.buffer[0], leavesCount * digestSize)

  # calculate intermediate nodes
  var concatBuf: array[2 * digestSize, byte]
  var prevLevel = levels[0]
  for level in levels[1..^1]:
    for i in 0..<level.width:
      let parentIndex = level.offset + i
      let leftChildIndex = prevLevel.offset + 2 * i
      let rightChildIndex = leftChildIndex + 1

      copyMem(addr concatBuf[0], addr tree.nodes[leftChildIndex], digestSize)

      if rightChildIndex < prevLevel.offset + prevLevel.width:
        copyMem(addr concatBuf[digestSize], addr tree.nodes[rightChildIndex], digestSize)
      else:
        copyMem(addr concatBuf[digestSize], addr zeroHash, digestSize)

      digestFn(concatBuf, tree.nodes[parentIndex])
    prevLevel = level

  return success(tree)

###########################################################
# MerkleTree
###########################################################

proc root*(self: MerkleTree): MerkleHash =
  self.nodes[^1]

proc len*(self: MerkleTree): Natural =
  self.nodes.len

proc leaves*(self: MerkleTree): seq[MerkleHash] =
  self.nodes[0..<self.leavesCount]

proc nodes*(self: MerkleTree): seq[MerkleHash] =
  self.nodes

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
  ## - 2,[HZ, H3] for data block C
  ## 
  ## where HZ=H(0x0b)
  ## 
  if index >= self.leavesCount:
    return failure("Index " & $index & " out of range [0.." & $self.leaves.high & "]" )

  let levels = computeLevels(self.leavesCount)
  var path = newSeq[MerkleHash](levels.len - 1)
  for levelIndex, level in levels[0..^2]:
    let i = index div (1 shl levelIndex)
    let siblingIndex = if i mod 2 == 0:
      level.offset + i + 1
    else:
      level.offset + i - 1
    
    if siblingIndex < level.offset + level.width:
      path[levelIndex] = self.nodes[siblingIndex]
    else:
      path[levelIndex] = zeroHash

  success(MerkleProof(index: index, path: path))

proc `$`*(self: MerkleTree): string =
  result &= "leavesCount: " & $self.leavesCount
  result &= "\nnodes: " & $self.nodes

###########################################################
# MerkleProof
###########################################################

proc index*(self: MerkleProof): Natural =
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
  index: Natural,
  path: seq[MerkleHash]
): MerkleProof =
  MerkleProof(index: index, path: path)
