import std/sequtils
import std/math
import std/bitops

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
    leafs: seq[MerkleHash]
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

  self.leafs.add(hash)
  return success()

func calcTreeHeight(leafsCount: int): int =
  if isPowerOfTwo(leafsCount): 
    fastLog2(leafsCount) + 1
  else:
    fastLog2(leafsCount) + 2

proc build*(self: MerkleTreeBuilder): ?!MerkleTree =
  let height = calcTreeHeight(self.leafs.len)
  var nodes = newSeq[seq[MerkleHash]](height)

  without mcodec =? self.mcodec:
    return failure("No hash codec defined, possibly no leafs were added")

  # copy leafs
  nodes[0] = newSeq[MerkleHash](self.leafs.len)
  for j in 0..<self.leafs.len:
    nodes[0][j] = self.leafs[j]

  # calculate internal nodes
  for i in 1..<height:
    let levelWidth = (nodes[i-1].len + 1) div 2
    nodes[i] = newSeq[MerkleHash](levelWidth)

    for j in 0..<levelWidth:
      let l = nodes[i-1][2 * j]
      let r = nodes[i-1][min(2 * j + 1, nodes[i-1].high)]
      var buf = newSeq[byte](l.size + r.size)
      copyMem(addr buf[0], unsafeAddr l.data.buffer[0], l.size)
      copyMem(addr buf[l.size], unsafeAddr r.data.buffer[0], r.size)

      nodes[i][j] = MultiHash.digest($mcodec, buf).tryGet()

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
  leafsLen: int
): MerkleTree =
  let height = calcTreeHeight(leafsLen)
  var nodes = newSeq[seq[MerkleHash]](height)
  nodes[^1] = @[root]
  MerkleTree(nodes: nodes)

proc len*(self: MerkleProof): int =
  self.path.len

proc `[]`*(self: MerkleProof, i: Natural) : MerkleHash {.inline.} =
  # This allows reading by [0], but not assigning.
  self.path[i]
