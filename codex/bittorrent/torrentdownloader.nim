{.push raises: [].}

import std/sequtils
import std/sugar
import pkg/chronos
import pkg/libp2p/multihash
import pkg/questionable/results

import ../rng
import ../logutils
import ../utils/iter
import ../errors
import ../manifest
import ../blocktype
import ../stores/networkstore
import ./manifest

logScope:
  topics = "codex piecedownloader"

type
  PieceHandle* = Future[void].Raising([CancelledError])
  TorrentPiece* = ref object
    pieceIndex: int
    pieceHash: MultiHash
    blockIndexStart: int
    blockIndexEnd: int
    handle: PieceHandle
    randomIndex: int

  TorrentDownloader* = ref object
    torrentManifest: BitTorrentManifest
    codexManifest: Manifest
    networkStore: NetworkStore
    numberOfPieces: int
    numberOfBlocksPerPiece: int
    pieces: seq[TorrentPiece]
    waitIter: Iter[int]
    queue: AsyncQueue[TorrentPiece]

proc newTorrentPiece*(
    pieceIndex: int, pieceHash: MultiHash, blockIndexStart: int, blockIndexEnd: int
): TorrentPiece =
  TorrentPiece(
    pieceIndex: pieceIndex,
    pieceHash: pieceHash,
    blockIndexStart: blockIndexStart,
    blockIndexEnd: blockIndexEnd,
    handle: cast[PieceHandle](newFuture[void]("PieceValidator.newTorrentPiece")),
  )

proc randomize(self: TorrentPiece, numberOfPieces: int): void =
  self.randomIndex = Rng.instance.rand(max = numberOfPieces * 10)

proc newTorrentDownloader*(
    torrentManifest: BitTorrentManifest,
    codexManifest: Manifest,
    networkStore: NetworkStore,
): ?!TorrentDownloader =
  let numOfPieces = torrentManifest.info.pieces.len
  let numOfBlocksPerPiece =
    torrentManifest.info.pieceLength.int div codexManifest.blockSize.int

  let pieces = collect:
    for i in 0 ..< numOfPieces:
      let piece = newTorrentPiece(
        pieceIndex = i,
        pieceHash = torrentManifest.info.pieces[i],
        blockIndexStart = i * numOfBlocksPerPiece,
        blockIndexEnd = ((i + 1) * numOfBlocksPerPiece) - 1,
      )
      piece

  let queue = newAsyncQueue[TorrentPiece](maxsize = numOfPieces)

  # optional: randomize the order of pieces
  # not sure if this is such a great idea when streaming content
  let iter = Iter.new(0 ..< numOfPieces)
  var pieceDownloadSequence = newSeqWith(numOfPieces, iter.next())
  Rng.instance.shuffle(pieceDownloadSequence)

  trace "Piece download sequence", pieceDownloadSequence

  for i in pieceDownloadSequence:
    try:
      queue.addLastNoWait(pieces[i])
    except AsyncQueueFullError:
      raiseAssert "Fatal: could not add pieces to queue"

  TorrentDownloader(
    torrentManifest: torrentManifest,
    codexManifest: codexManifest,
    networkStore: networkStore,
    numberOfPieces: numOfPieces,
    numberOfBlocksPerPiece: numOfBlocksPerPiece,
    pieces: pieces,
    waitIter: Iter[int].new(0 ..< numOfPieces),
    queue: queue,
  ).success

func numberOfBlocksPerPiece*(self: TorrentDownloader): int =
  self.numberOfBlocksPerPiece

proc getNewPieceIterator*(self: TorrentDownloader): Iter[int] =
  Iter[int].new(0 ..< self.numberOfPieces)

proc getNewBlocksPerPieceIterator*(self: TorrentDownloader): Iter[int] =
  Iter[int].new(0 ..< self.numberOfBlocksPerPiece)

proc getBlockIterator(self: TorrentPiece): Iter[int] =
  Iter[int].new(self.blockIndexStart .. self.blockIndexEnd)

proc waitForNextPiece*(
    self: TorrentDownloader
): Future[int] {.async: (raises: [CancelledError]).} =
  if self.waitIter.finished:
    return -1
  let pieceIndex = self.waitIter.next()
  await self.pieces[pieceIndex].handle
  pieceIndex

proc cancel*(self: TorrentDownloader): Future[void] {.async: (raises: []).} =
  await noCancel allFutures(self.pieces.mapIt(it.handle.cancelAndWait))

proc validate*(piece: TorrentPiece, blocks: seq[Block]): ?!void {.raises: [].} =
  var pieceHashCtx: sha1
  pieceHashCtx.init()

  for blk in blocks:
    pieceHashCtx.update(blk.data)

  let computedPieceHash = pieceHashCtx.finish()

  if (computedPieceHash != piece.pieceHash):
    return failure("Piece verification failed")

  success()

proc allBlocksFinished*(futs: seq[Future[?!Block]]): seq[?!Block] {.raises: [].} =
  ## If all futures have finished, return corresponding values,
  ## otherwise return failure
  ##

  try:
    let values = collect:
      for b in futs:
        if b.finished:
          b.read
    return values
  except CatchableError as e:
    raiseAssert e.msg

proc deleteBlocks(
    self: TorrentDownloader, piece: TorrentPiece
): Future[void] {.async: (raises: [CancelledError]).} =
  let treeCid = self.codexManifest.treeCid
  let blockIter = piece.getBlockIterator()
  while not blockIter.finished:
    # deleting a block that is not in localStore is harmless
    # blocks that are in localStore and in use will not be deleted
    try:
      if err =? (await self.networkStore.localStore.delBlock(treeCid, blockIter.next())).errorOption:
        warn "Could not delete block", err = err.msg
        continue
    except CatchableError as e:
      warn "Could not delete block", error = e.msg
      continue

proc getSuccessfulBlocks(futs: seq[Future[?!Block]]): ?!seq[Block] {.raises: [].} =
  let blockResults = allBlocksFinished(futs)
  if blockResults.len != futs.len or blockResults.anyIt(it.isFailure):
    return failure("Some blocks failed to fetch")
  success blockResults.mapIt(it.get)

proc fetchPiece*(
    self: TorrentDownloader, piece: TorrentPiece
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let treeCid = self.codexManifest.treeCid
  let blockIter = piece.getBlockIterator()
  var blockFutures = newSeq[Future[?!Block]]()
  for blockIndex in blockIter:
    let address = BlockAddress.init(treeCid, blockIndex)
    blockFutures.add(self.networkStore.getBlock(address))

  await allFutures(blockFutures)

  without blocks =? getSuccessfulBlocks(blockFutures), err:
    await self.deleteBlocks(piece)
    return failure(err)

  # all blocks in piece are there: we are ready for validation
  if err =? piece.validate(blocks).errorOption:
    # we do not know on which block validation failed
    # thus we try to delete as many as we can
    await self.deleteBlocks(piece)
    return failure(err)

  success()

proc downloadPieces*(self: TorrentDownloader): Future[?!void] {.async: (raises: []).} =
  try:
    while not self.queue.empty:
      let piece = self.queue.popFirstNoWait()
      if err =? (await self.fetchPiece(piece)).errorOption:
        error "Could not fetch piece", err = err.msg
        # add the piece to the end of the queue
        # to try to fetch the piece again
        self.queue.addLastNoWait(piece)
        continue
      else:
        # piece fetched and validated successfully
        # mark it as ready
        piece.handle.complete()
      await sleepAsync(1.millis)
  except CancelledError:
    trace "Downloading pieces cancelled"
  except AsyncQueueFullError as e:
    error "Queue is full", error = e.msg
    return failure e
  except AsyncQueueEmptyError as e:
    error "Trying to pop from empty queue", error = e.msg
    return failure e
  finally:
    await noCancel self.cancel()
  success()

#################################################################
# Previous API, keeping it for now, probably will not be needed
#
#################################################################

proc waitForPiece*(
    self: TorrentDownloader, index: int
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  await self.pieces[index].handle
  success()

proc cancelPiece*(
    self: TorrentDownloader, index: int
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  await noCancel self.pieces[index].handle.cancelAndWait()
  success()

proc confirmPiece*(self: TorrentDownloader, index: int): ?!void {.raises: [].} =
  if index < 0 or index >= self.pieces.len:
    return failure("Invalid piece index")
  self.pieces[index].handle.complete()
  success()
