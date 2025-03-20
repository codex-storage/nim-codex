{.push raises: [].}

import std/sequtils
import pkg/chronos
import pkg/libp2p/multihash
import pkg/questionable/results

import ../utils/iter
import ../manifest
import ../blocktype
import ./manifest

type
  PieceHandle* = Future[void].Raising([CancelledError])
  TorrentPieceValidator* = ref object
    torrentManifest: BitTorrentManifest
    numberOfPieces: int
    numberOfBlocksPerPiece: int
    pieces: seq[PieceHandle]
    waitIter: Iter[int]
    confirmIter: Iter[int]
    validationIter: Iter[int]

proc newTorrentPieceValidator*(
    torrentManifest: BitTorrentManifest, codexManifest: Manifest
): TorrentPieceValidator =
  let numOfPieces = torrentManifest.info.pieces.len
  let numOfBlocksPerPiece =
    torrentManifest.info.pieceLength.int div codexManifest.blockSize.int
  let pieces = newSeqWith(
    numOfPieces,
    cast[PieceHandle](newFuture[void]("PieceValidator.newTorrentPieceValidator")),
  )

  TorrentPieceValidator(
    torrentManifest: torrentManifest,
    numberOfPieces: numOfPieces,
    numberOfBlocksPerPiece: numOfBlocksPerPiece,
    pieces: pieces,
    waitIter: Iter[int].new(0 ..< numOfPieces),
    confirmIter: Iter[int].new(0 ..< numOfPieces),
    validationIter: Iter[int].new(0 ..< numOfPieces),
  )

func numberOfBlocksPerPiece*(self: TorrentPieceValidator): int =
  self.numberOfBlocksPerPiece

proc getNewPieceIterator*(self: TorrentPieceValidator): Iter[int] =
  Iter[int].new(0 ..< self.numberOfPieces)

proc getNewBlocksPerPieceIterator*(self: TorrentPieceValidator): Iter[int] =
  Iter[int].new(0 ..< self.numberOfBlocksPerPiece)

proc waitForNextPiece*(
    self: TorrentPieceValidator
): Future[bool] {.async: (raises: [CancelledError]).} =
  if self.waitIter.finished:
    return false
  await self.pieces[self.waitIter.next()]
  true

proc confirmCurrentPiece*(self: TorrentPieceValidator): bool {.raises: [].} =
  if self.confirmIter.finished:
    return false
  self.pieces[self.confirmIter.next()].complete()
  true

proc cancel*(self: TorrentPieceValidator): Future[void] {.async: (raises: []).} =
  await noCancel allFutures(self.pieces.mapIt(it.cancelAndWait))

proc validatePiece*(
    self: TorrentPieceValidator, blocks: seq[Block]
): bool {.raises: [].} =
  var pieceHashCtx: sha1
  pieceHashCtx.init()

  for blk in blocks:
    pieceHashCtx.update(blk.data)

  let computedPieceHash = pieceHashCtx.finish()

  if (computedPieceHash != self.torrentManifest.info.pieces[self.validationIter.next()]):
    return false

  true

#################################################################
# Previous API, keeping it for now, probably will not be needed
#
#################################################################

proc waitForPiece*(
    self: TorrentPieceValidator, index: int
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  await self.pieces[index]
  success()

proc cancelPiece*(
    self: TorrentPieceValidator, index: int
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  await noCancel self.pieces[index].cancelAndWait()
  success()

proc markPieceAsValid*(self: TorrentPieceValidator, index: int): ?!void {.raises: [].} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  self.pieces[index].complete()
  success()

proc validatePiece*(
    self: TorrentPieceValidator, blocks: seq[Block], index: int
): ?!void {.raises: [].} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")

  var pieceHashCtx: sha1
  pieceHashCtx.init()

  for blk in blocks:
    pieceHashCtx.update(blk.data)

  let computedPieceHash = pieceHashCtx.finish()

  # if index == 1:
  #   return failure("Piece verification failed (simulated)")

  if (computedPieceHash != self.torrentManifest.info.pieces[index]):
    return failure("Piece verification failed")

  success()
