import std/sugar

import pkg/chronos
import pkg/libp2p/cid

import pkg/codex/codextypes
import pkg/codex/stores
import pkg/codex/merkletree
import pkg/codex/manifest
import pkg/codex/blocktype as bt
import pkg/codex/chunker
import pkg/codex/rng
import pkg/taskpools

import ../helpers

proc makeManifestBlock*(manifest: Manifest): ?!bt.Block =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  success blk

proc storeManifest*(
    store: BlockStore, manifest: Manifest
): Future[?!bt.Block] {.async.} =
  without blk =? makeManifestBlock(manifest), err:
    trace "Unable to create manifest block", err = err.msg
    return failure(err)

  if err =? (await store.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc makeManifest*(
    cids: seq[Cid],
    datasetSize: NBytes,
    blockSize: NBytes,
    store: BlockStore,
    hcodec = Sha256HashCodec,
    dataCodec = BlockCodec,
): Future[?!Manifest] {.async.} =
  without tree =? CodexTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)

    if err =? (await store.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = datasetSize,
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
  )

  without manifestBlk =? await store.storeManifest(manifest), err:
    trace "Unable to store manifest"
    return failure(err)

  success manifest

proc createBlocks*(
    chunker: Chunker, store: BlockStore
): Future[seq[bt.Block]] {.async.} =
  collect(newSeq):
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      let blk = bt.Block.new(chunk).tryGet()
      discard await store.putBlock(blk)
      blk
