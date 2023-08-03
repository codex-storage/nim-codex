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
  MerkleTreeBuilder* = ref object of RootObj
    mcodec: ?MultiCodec
    leaves: seq[MerkleHash]
  MerkleProof* = ref object of RootObj
    path: seq[MerkleHash]

proc `$`*(t: MerkleTree): string =
  result &= "height: " & $t.nodes.len
  result &= "\nnodes: " & $t.nodes

proc addLeaf*(self: MerkleTreeBuilder, hash: MerkleHash): ?!void =
  if codec =? self.mcodec:
    if codec != hash.mcodec:
      return failure("Expected codec is " & $codec & " but " & $hash.mcodec & " received")
  else:
    self.mcodec = hash.mcodec.some

  self.leaves.add(hash)
  return success()

func calcTreeHeight(leavesCount: int): int =
  if isPowerOfTwo(leavesCount): 
    fastLog2(leavesCount) + 1
  else:
    fastLog2(leavesCount) + 2

proc build*(self: MerkleTreeBuilder): ?!MerkleTree =
  let height = calcTreeHeight(self.leaves.len)
  var nodes = newSeq[seq[MerkleHash]](height)

  without mcodec =? self.mcodec and 
          digestSize =? self.leaves.?[0].?size:
    return failure("Unable to determine codec, no leaves were added")

  var buf = newSeq[byte](digestSize * 2)
  proc combine(l, r: MerkleHash): ?!MerkleHash =
    copyMem(addr buf[0], unsafeAddr l.data.buffer[0], digestSize)
    copyMem(addr buf[digestSize], unsafeAddr r.data.buffer[0], digestSize)

    MultiHash.digest($mcodec, buf).mapErr(
      c => newException(CatchableError, "Error calculating hash using codec " & $mcodec & ": " & $c)
    )

  # copy leaves
  nodes[0] = newSeq[MerkleHash](self.leaves.len)
  for j in 0..<self.leaves.len:
    nodes[0][j] = self.leaves[j]

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

proc leaves*(self: MerkleTree): seq[MerkleHash] =
  self.nodes[0]

proc len*(self: MerkleTree): int =
  self.nodes.foldl(a + b.len, 0)

proc getProof*(self: MerkleTree, index: int): ?!MerkleProof =
  failure("not implemented")

proc addProof*(self: MerkleTree, index: int, proof: MerkleProof): ?!void =
  failure("not implemented")

func new*(
  T: type MerkleTree,
  root: MerkleHash,
  leavesCount: int
): MerkleTree =
  let height = calcTreeHeight(leavesCount)
  var nodes = newSeq[seq[MerkleHash]](height)
  nodes[^1] = @[root]
  MerkleTree(nodes: nodes)

proc len*(self: MerkleProof): int =
  self.path.len

proc `[]`*(self: MerkleProof, i: Natural) : MerkleHash {.inline.} =
  # This allows reading by [0], but not assigning.
  self.path[i]
