import pkg/chronos
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/questionable/results

import pkg/codex/stores/cachestore
import pkg/codex/utils/iter

import pkg/codex/manifest
import pkg/codex/bittorrent/manifest

proc torrentInfoForCodexManifest*(
    localStore: BlockStore,
    codexManifest: Manifest,
    pieceLength = DefaultPieceLength.int,
    name = string.none,
): Future[?!BitTorrentInfo] {.async.} =
  let treeCid = codexManifest.treeCid
  let datasetSize = codexManifest.datasetSize
  let blockSize = codexManifest.blockSize
  let numOfBlocks = divUp(datasetSize, blockSize)
  let blockIter = Iter.new(0 ..< numOfBlocks)
  var blocks = newSeq[Block](numOfBlocks)
  while not blockIter.finished:
    let index = blockIter.next()
    without blk =? (await localStore.getBlock(treeCid, index)), err:
      return failure(err)
    blocks[index] = blk
  let
    numOfBlocksPerPiece = pieceLength div BitTorrentBlockSize.int
    numOfPieces = divUp(datasetSize, pieceLength.NBytes)

  var
    pieces: seq[MultiHash]
    pieceHashCtx: sha1
    pieceIter = Iter[int].new(0 ..< numOfBlocksPerPiece)

  pieceHashCtx.init()

  for blk in blocks:
    if blk.data.len == 0:
      break
    if pieceIter.finished:
      without mh =? MultiHash.init($Sha1HashCodec, pieceHashCtx.finish()).mapFailure,
        err:
        return failure(err)
      pieces.add(mh)
      pieceIter = Iter[int].new(0 ..< numOfBlocksPerPiece)
      pieceHashCtx.init()
    pieceHashCtx.update(blk.data)
    discard pieceIter.next()

  without mh =? MultiHash.init($Sha1HashCodec, pieceHashCtx.finish()).mapFailure, err:
    return failure(err)
  pieces.add(mh)

  let info = BitTorrentInfo(
    length: datasetSize.uint64,
    pieceLength: pieceLength.uint32,
    pieces: pieces,
    name: name,
  )

  success info

proc storeCodexManifest*(
    codexManifest: Manifest, localStore: BlockStore
): Future[?!Block] {.async.} =
  without encodedManifest =? codexManifest.encode(), err:
    trace "Unable to encode manifest", err = err.msg
    return failure(err)

  without blk =? Block.new(data = encodedManifest, codec = ManifestCodec), err:
    trace "Unable to create block from manifest", err = err.msg
    return failure(err)

  if err =? (await localStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc storeTorrentManifest*(
    torrentManifest: BitTorrentManifest, localStore: BlockStore
): Future[?!Block] {.async.} =
  let infoBencoded = torrentManifest.info.bencode()
  let infoHash = MultiHash.digest($Sha1HashCodec, infoBencoded).tryGet
  let encodedManifest = torrentManifest.encode()

  without infoHashCid =? Cid.init(CIDv1, InfoHashV1Codec, infoHash).mapFailure, err:
    trace "Unable to create CID for BitTorrent info hash", err = err.msg
    return failure(err)

  without blk =? Block.new(data = encodedManifest, cid = infoHashCid, verify = false),
    err:
    trace "Unable to create block from manifest", err = err.msg
    return failure(err)

  if err =? (await localStore.putBlock(blk)).errorOption:
    trace "Unable to store BitTorrent manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk
