# import std/sequtils
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

import std/bitops

type
  MerkleHash* = MultiHash
  MerkleTree* = ref object of RootObj
    root: MerkleHash
    nodes: seq[MerkleHash]
  MerkleTreeBuilder* = ref object of RootObj
    mcodec: ?MultiCodec
    leafs: seq[MerkleHash]
  MerkleProof* = ref object of RootObj
    path: seq[MerkleHash]

# proc `$`*(h: MerkleHash): string =
#   h.toHex

proc `$`*(t: MerkleTree): string =
  result &= "size: " & $t.nodes.len
  result &= "\nnodes: " & $t.nodes

proc addLeaf*(self: MerkleTreeBuilder, hash: MerkleHash): ?!void =
  if codec =? self.mcodec:
    if codec != hash.mcodec:
      return failure("Expected codec is " & $codec & " but " & $hash.mcodec & " received")
  else:
    self.mcodec = hash.mcodec.some

  self.leafs.add(hash)
  return success()


#    h1233
#   /     \
#  h12   h33
#  / \   / \
# h1 h2 h3

# [ 0,   1,  2,   3,   4,     5]
# [ h1, h2, h3, h12, h33, h1233]
#

# l = 6 - (2 * 3 + 1)

# l =
# r = l + 1

#
# [ h1233, h12, h33, h1, h2, h3 ]
#

# l = 2n + 1
# r = 2n + 2

# 2 * 1 + 1
# 2 * 1 + 2


# 3 -> 0, 1
# 4 -> 2, (2)
#

func calcTreeSize(n: int): int =
    let l = fastLog2(n)
    let m = 1 shl l
    if m == n:
      return m - 1 + n
    else:
      return m shl 1 - 1 + n

proc build*(self: MerkleTreeBuilder): MerkleTree =
  let tsize = calcTreeSize(self.leafs.len)
  var nodes = newSeq[MerkleHash](tsize)

  for i in 0..<self.leafs.len:
    nodes[i] = self.leafs[i]


  MerkleTree(nodes: nodes)

proc rootHash*(self: MerkleTree): MerkleHash =
  # This is a proc not a field to make it readonly.
  self.root

proc numberOfLeafs*(self: MerkleTree): int =
  1

proc len*(self: MerkleTree): int =
  self.nodes.len

proc getLeaf*(self: MerkleTree, index: int): ?!MerkleHash =
  failure("not implemented")

proc getProof*(self: MerkleTree, index: int): ?!MerkleProof =
  failure("not implemented")

proc addProof*(self: MerkleTree, index: int, proof: MerkleProof): ?!void =
  failure("not implemented")

func new*(
  T: type MerkleTree,
  rootHash: MerkleHash
): MerkleTree =
  MerkleTree(
    root: rootHash)

proc len*(self: MerkleProof): int =
  self.path.len

proc `[]`*(self: MerkleProof, i: Natural) : MerkleHash {.inline.} =
  # This allows reading by [0], but not assigning.
  self.path[i]
