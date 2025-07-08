import std/random

import pkg/codex/blocktype as bt
import pkg/codex/merkletree
import pkg/codex/manifest

type TestDataset* = tuple[blocks: seq[Block], tree: CodexTree, manifest: Manifest]

proc makeRandomBlock*(size: NBytes): Block =
  let bytes = newSeqWith(size.int, rand(uint8))
  Block.new(bytes).tryGet()

proc makeRandomBlocks*(nBlocks: int, blockSize: NBytes): seq[Block] =
  for i in 0 ..< nBlocks:
    result.add(makeRandomBlock(blockSize))

proc makeDataset*(blocks: seq[Block]): ?!TestDataset =
  if blocks.len == 0:
    return failure("Blocks list was empty")

  let
    datasetSize = blocks.mapIt(it.data.len).foldl(a + b)
    blockSize = blocks.mapIt(it.data.len).foldl(max(a, b))
    tree = ?CodexTree.init(blocks.mapIt(it.cid))
    treeCid = ?tree.rootCid
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = NBytes(blockSize),
      datasetSize = NBytes(datasetSize),
    )

  return success((blocks, tree, manifest))

proc makeRandomDataset*(nBlocks: int, blockSize: NBytes): ?!TestDataset =
  makeDataset(makeRandomBlocks(nBlocks, blockSize))
