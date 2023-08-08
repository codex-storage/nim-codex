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

func getChildren(self: MerkleTree, i, j: int): (MerkleHash, MerkleHash) =
  let (low, high) = self.getLowHigh(i - 1)
  let leftIdx = low + 2 * j
  let rightIdx = min(leftIdx + 1, high)

  (self.nodes[leftIdx], self.nodes[rightIdx])

func getSibling(self: MerkleTree, i, j: int): MerkleHash =
  let (low, high) = self.getLowHigh(i)
  if j mod 2 == 0:
    self.nodes[min(low + j + 1, high)]
  else:
    self.nodes[low + j - 1]

proc setNode(self: var MerkleTree, i, j: int, value: MerkleHash): void =
  let (low, _) = self.getLowHigh(i)
  self.nodes[low + j] = value

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
  for i in 0..<path.len:
    let j = index div (1 shl i)
    path[i] = self.getSibling(i, j)

  success(MerkleProof(index: index, path: path))

proc initTreeFromLeaves(leaves: seq[MerkleHash]): ?!MerkleTree =

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
  for j in 0..<leaves.len:
    tree.setNode(0, j, leaves[j])

  # calculate intermediate nodes
  for i in 1..<tree.height:
    for j in 0..<tree.getWidth(i):
      let (left, right) = tree.getChildren(i, j)
      
      without mhash =? combine(left, right), error:
        return failure(error)
      tree.setNode(i, j, mhash)

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
  leaves: seq[MerkleHash]
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
