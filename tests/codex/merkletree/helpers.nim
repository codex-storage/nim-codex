import pkg/codex/merkletree
import ../helpers

export merkletree, helpers

proc `==`*(a, b: StorageMerkleTree): bool =
  (a.mcodec == b.mcodec) and (a.leavesCount == b.leavesCount) and (a.levels == b.levels)

proc `==`*(a, b: StorageMerkleProof): bool =
  (a.mcodec == b.mcodec) and (a.nleaves == b.nleaves) and (a.path == b.path) and
    (a.index == b.index)
