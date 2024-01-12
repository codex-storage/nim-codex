import pkg/libp2p
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results
import pkg/poseidon2
import pkg/poseidon2/io

import ../merkletree
import ../utils
import ../utils/digest
import ../blocktype as bt
import ../utils/poseidon2digest
import ./proofpadding

type ProofBlock* = object of RootObj
  padding: ProofPadding
  tree: ?Poseidon2Tree

proc new*(
  T: type ProofBlock,
  padding: ProofPadding,
  blk: bt.Block,
  cellSize: NBytes): ?!ProofBlock =

  if blk.isEmpty:
    return success(ProofBlock(
      padding: padding,
      tree: Poseidon2Tree.none
    ))
  else:
    without tree =? Poseidon2Tree.digestTree(blk.data & padding.blockPadBytes, cellSize.int), err:
      error "Failed to create tree for block", error = err.msg
      return failure(err)
    return success(ProofBlock(
      padding: padding,
      tree: tree.some
    ))

proc root*(self: ProofBlock): ?!Poseidon2Hash =
  if self.tree.isSome:
    return self.tree.get().root()
  success(self.padding.blockEmptyDigest)

proc proof*(self: ProofBlock, blockCellIndex: int): ?!Poseidon2Proof =
  if self.tree.isSome:
    return self.tree.get().getProof(blockCellIndex)
  failure("Can't get proof from empty block")
