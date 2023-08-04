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
  MerkleTree* = ref object of RootObj
    nodes: seq[seq[MerkleHash]]
  MerkleProof* = ref object of RootObj
    index*: int
    path*: seq[MerkleHash]

func calcTreeHeight(leavesCount: int): int =
  if isPowerOfTwo(leavesCount): 
    fastLog2(leavesCount) + 1
  else:
    fastLog2(leavesCount) + 2

proc newTree(leaves: seq[MerkleHash]): ?!MerkleTree =

  without mcodec =? leaves.?[0].?mcodec and
          digestSize =? leaves.?[0].?size:
    return failure("At least one leaf is required")

  if not leaves.allIt(it.mcodec == mcodec):
    return failure("All leaves must use the same codec")

  let height = calcTreeHeight(leaves.len)
  var nodes = newSeq[seq[MerkleHash]](height)

  var buf = newSeq[byte](digestSize * 2)
  proc combine(l, r: MerkleHash): ?!MerkleHash =
    copyMem(addr buf[0], unsafeAddr l.data.buffer[0], digestSize)
    copyMem(addr buf[digestSize], unsafeAddr r.data.buffer[0], digestSize)

    MultiHash.digest($mcodec, buf).mapErr(
      c => newException(CatchableError, "Error calculating hash using codec " & $mcodec & ": " & $c)
    )

  # copy leaves
  nodes[0] = newSeq[MerkleHash](leaves.len)
  for j in 0..<leaves.len:
    nodes[0][j] = leaves[j]

  # calculate internal nodes
  for i in 1..<height:
    let levelWidth = (nodes[i-1].len + 1) div 2
    nodes[i] = newSeq[MerkleHash](levelWidth)

    for j in 0..<levelWidth:
      let l = nodes[i-1][2 * j]
      let r = nodes[i-1][min(2 * j + 1, nodes[i-1].high)]
      
      without mhash =? combine(l, r), error:
        return failure(error)
      
      nodes[i][j] = mhash

  success(MerkleTree(nodes: nodes))

proc root*(self: MerkleTree): MerkleHash =
  self.nodes[^1][0]

proc len*(self: MerkleTree): int =
  self.nodes.foldl(a + b.len, 0)

proc leaves*(self: MerkleTree): seq[MerkleHash] =
  self.nodes[0]

proc height*(self: MerkleTree): int =
  self.nodes.len

proc getProof*(self: MerkleTree, index: int): ?!MerkleProof =
  if index > self.leaves.high or index < 0:
    return failure("Index " & $index & " out of range [0.." & $self.leaves.high & "]" )

  var path = newSeq[MerkleHash](self.height - 1)
  for i in 0..<path.len:
    let p = index div (1 shl i)
    path[i] = 
      if p mod 2 == 0:
        self.nodes[i][min(p + 1, self.nodes[i].high)]
      else:
        self.nodes[i][p - 1]

  success(MerkleProof(index: index, path: path))

func new*(
  T: type MerkleTree,
  root: MerkleHash,
  leavesCount: int
): MerkleTree =
  let height = calcTreeHeight(leavesCount)
  var nodes = newSeq[seq[MerkleHash]](height)
  nodes[^1] = @[root]
  MerkleTree(nodes: nodes)

proc new*(
  T: type MerkleTree,
  leaves: seq[MerkleHash]
): ?!MerkleTree =
  newTree(leaves)

proc len*(self: MerkleProof): int =
  self.path.len

proc `[]`*(self: MerkleProof, i: Natural) : MerkleHash {.inline.} =
  # This allows reading by [0], but not assigning.
  self.path[i]

proc `$`*(t: MerkleTree): string =
  result &= "height: " & $t.nodes.len
  result &= "\nnodes: " & $t.nodes

proc `$`*(self: MerkleProof): string =
  result &= "index: " & $self.index
  result &= "\nleaves: " & $self.index

func `==`*(a, b: MerkleProof): bool =
  (a.index == b.index) and (a.path == b.path)