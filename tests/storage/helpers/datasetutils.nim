import std/random

import pkg/chronos
import pkg/libp2p/cid
import pkg/storage/blocktype as bt
import pkg/storage/merkletree
import pkg/storage/manifest
import pkg/storage/rng

import ./randomchunker

type TestDataset* =
  tuple[
    blocks: seq[Block], tree: StorageMerkleTree, manifest: Manifest, manifestCid: Cid
  ]

proc manifestDesc*(ds: TestDataset): ManifestDescriptor =
  ManifestDescriptor(manifest: ds.manifest, manifestCid: ds.manifestCid)

proc makeRandomBlock*(size: NBytes): Block =
  let bytes = newSeqWith(size.int, rand(uint8))
  Block.new(bytes).tryGet()

proc makeRandomBlocks*(
    datasetSize: int, blockSize: NBytes
): Future[seq[Block]] {.async.} =
  var chunker =
    RandomChunker.new(Rng.instance(), size = datasetSize, chunkSize = blockSize)

  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break

    result.add(Block.new(chunk).tryGet())

proc makeDataset*(
    blocks: seq[Block], mimetype: Option[string] = string.none
): ?!TestDataset =
  if blocks.len == 0:
    return failure("Blocks list was empty")

  let
    datasetSize = blocks.mapIt(it.data[].len).foldl(a + b)
    blockSize = blocks.mapIt(it.data[].len).foldl(max(a, b))
    tree = ?StorageMerkleTree.init(blocks.mapIt(it.cid))
    treeCid = ?tree.rootCid
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = NBytes(blockSize),
      datasetSize = NBytes(datasetSize),
      mimetype = mimetype,
    )
    manifestBlock = ?Block.new(?manifest.encode(), codec = ManifestCodec)

  return success((blocks, tree, manifest, manifestBlock.cid))
