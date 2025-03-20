import std/strformat

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/questionable/results

import ../../asynctest
import ../examples

import pkg/codex/manifest
import pkg/codex/bittorrent/manifest
import pkg/codex/bittorrent/piecevalidator

suite "Torrent PieceValidator":
  const numOfPieces = 10
  const pieceLength = 65536
  const contentLength = pieceLength * numOfPieces
  let pieces = newSeqWith(numOfPieces, MultiHash.example(Sha1HashCodec))
  let exampleInfo = BitTorrentInfo(
    length: contentLength,
    pieceLength: pieceLength,
    pieces: pieces,
    name: "data.bin".some,
  )
  let dummyCodexManifestCid = Cid.example()
  let exampleTorrentManifest =
    newBitTorrentManifest(info = exampleInfo, codexManifestCid = dummyCodexManifestCid)
  let infoBencoded = exampleInfo.bencode()
  let infoHash = MultiHash.digest($Sha1HashCodec, infoBencoded).tryGet
  let exampleCodexManifest = Manifest.new(
    treeCid = Cid.example,
    blockSize = BitTorrentBlockSize.NBytes,
    datasetSize = exampleInfo.length.NBytes,
    filename = exampleInfo.name,
    mimetype = "application/octet-stream".some,
  )

  var pieceValidator: TorrentPieceValidator

  setup:
    pieceValidator =
      newTorrentPieceValidator(exampleTorrentManifest, exampleCodexManifest)

  test "correctly sets numberOfBlocksPerPiece":
    check pieceValidator.numberOfBlocksPerPiece ==
      exampleInfo.pieceLength.int div exampleCodexManifest.blockSize.int

  test "reports an error when trying to wait for an invalid piece":
    let res = await pieceValidator.waitForPiece(exampleTorrentManifest.info.pieces.len)
    check isFailure(res)
    check res.error.msg == "Invalid piece index"

  test "reports an error when trying to mark an invalid piece as valid":
    let res = pieceValidator.markPieceAsValid(exampleTorrentManifest.info.pieces.len)
    check isFailure(res)
    check res.error.msg == "Invalid piece index"

  for i in 0 ..< exampleTorrentManifest.info.pieces.len:
    test fmt"can await piece {i}":
      let fut = pieceValidator.waitForPiece(i)
      check pieceValidator.markPieceAsValid(i) == success()
      check (await fut) == success()

  test "awaiting for piece can be cancelled":
    let pieceIndex = 0
    let fut = pieceValidator.waitForPiece(pieceIndex)
    check (await pieceValidator.cancelPiece(pieceIndex)) == success()
    let res = catch(await fut)
    check isFailure(res)
    check res.error of CancelledError

  test "all pieces can be cancelled":
    let fut1 = pieceValidator.waitForPiece(1)
    let fut2 = pieceValidator.waitForPiece(2)

    await pieceValidator.cancel()

    let res1 = catch(await fut1)
    check isFailure(res1)
    check res1.error of CancelledError
    let res2 = catch(await fut2)
    check isFailure(res2)
    check res2.error of CancelledError

  test "awaiting all pieces sequentially":
    let numberOfPieces = exampleTorrentManifest.info.pieces.len
    for i in 0 ..< numberOfPieces:
      let fut = pieceValidator.waitForNextPiece()
      check pieceValidator.confirmCurrentPiece()
      check await fut

  test "awaiting is independent from confirming":
    let numberOfPieces = exampleTorrentManifest.info.pieces.len
    var futs = newSeq[Future[bool]](numberOfPieces)
    for i in 0 ..< numberOfPieces:
      futs[i] = pieceValidator.waitForNextPiece()
    for i in 0 ..< numberOfPieces:
      check pieceValidator.confirmCurrentPiece()
    for i in 0 ..< numberOfPieces:
      check await futs[i]

  test "sequential validation of blocks":
    let blocksInPieces = newSeqWith(
      numOfPieces,
      newSeqWith(
        pieceLength div BitTorrentBlockSize.int, Block.example(BitTorrentBlockSize.int)
      ),
    )
    var pieces = newSeq[MultiHash](blocksInPieces.len)
    for i in 0 ..< blocksInPieces.len:
      let blocks = blocksInPieces[i]
      var pieceHashCtx: sha1
      pieceHashCtx.init()
      for blk in blocks:
        pieceHashCtx.update(blk.data)
      pieces[i] = MultiHash.init($Sha1HashCodec, pieceHashCtx.finish()).tryGet

    let info = BitTorrentInfo(
      length: contentLength,
      pieceLength: pieceLength,
      pieces: pieces,
      name: "data.bin".some,
    )
    let manifestCid = Cid.example()
    let torrentManifest =
      newBitTorrentManifest(info = info, codexManifestCid = manifestCid)
    let codexManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = BitTorrentBlockSize.NBytes,
      datasetSize = info.length.NBytes,
      filename = info.name,
      mimetype = "application/octet-stream".some,
    )

    pieceValidator = newTorrentPieceValidator(torrentManifest, codexManifest)

    for blks in blocksInPieces:
      # streaming client will wait on the piece validator to validate the piece
      let fut = pieceValidator.waitForNextPiece()

      # during prefetch we will validate each piece sequentially
      # piece validator maintains internal iterators in its object
      # to keep track of the validation order
      check pieceValidator.validatePiece(blks)

      # after piece is validated, the prefetch task will confirm the piece
      # again, using internal state, the validator knows which piece to confirm
      check pieceValidator.confirmCurrentPiece()

      # the fut will be resolved after the piece is confirmed
      # and the streaming client can continue
      check await fut
