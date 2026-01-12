import pkg/codex/merkletree
import ../helpers

export merkletree, helpers

proc `==`*(a, b: CodexTree): bool =
  (a.mcodec == b.mcodec) and (a.leavesCount == b.leavesCount) and (a.levels == b.levels)

proc `==`*(a, b: CodexProof): bool =
  (a.mcodec == b.mcodec) and (a.nleaves == b.nleaves) and (a.path == b.path) and
    (a.index == b.index)
