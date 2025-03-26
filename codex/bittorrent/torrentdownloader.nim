{.push raises: [].}

# import std/asyncstreams
import std/sequtils
import std/sugar
import pkg/chronos
import pkg/libp2p/multihash
import pkg/questionable/results

# import ../rng
import ../logutils
import ../utils/iter
import ../utils/trackedfutures
import ../errors
import ../manifest
import ../blocktype
import ../stores/networkstore
import ./manifest

logScope:
  topics = "codex node torrentdownloader"

type
  PieceHandle* = Future[void].Raising([CancelledError])
  TorrentPiece* = ref object
    pieceIndex: int
    pieceHash: MultiHash
    blockIndexStart: int
    blockIndexEnd: int
    handle: PieceHandle

  TorrentDownloader* = ref object
    torrentManifest: BitTorrentManifest
    codexManifest: Manifest
    networkStore: NetworkStore
    numberOfPieces: int
    numberOfBlocksPerPiece: int
    pieces: seq[TorrentPiece]
    waitIter: Iter[int]
    blockIter: Iter[int]
    pieceIndex: int
    queue: AsyncQueue[TorrentPiece]
    trackedFutures: TrackedFutures

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

proc newTorrentDownloader*(
    torrentManifest: BitTorrentManifest,
    codexManifest: Manifest,
    networkStore: NetworkStore,
): ?!TorrentDownloader =
  let
    blocksCount = codexManifest.blocksCount
    numOfPieces = torrentManifest.info.pieces.len
    numOfBlocksPerPiece =
      torrentManifest.info.pieceLength.int div codexManifest.blockSize.int
    numOfBlocksInLastPiece = blocksCount - (numOfBlocksPerPiece * (numOfPieces - 1))

  let pieces = collect:
    for i in 0 ..< numOfPieces:
      var blockIndexEnd = ((i + 1) * numOfBlocksPerPiece) - 1
      if i == numOfPieces - 1:
        # last piece can have less blocks than numOfBlocksPerPiece
        blockIndexEnd = i * numOfBlocksPerPiece + numOfBlocksInLastPiece - 1

      let piece = newTorrentPiece(
        pieceIndex = i,
        pieceHash = torrentManifest.info.pieces[i],
        blockIndexStart = i * numOfBlocksPerPiece,
        blockIndexEnd = blockIndexEnd,
      )
      piece

  let queue = newAsyncQueue[TorrentPiece](maxsize = numOfPieces)

  let iter = Iter.new(0 ..< numOfPieces)
  var pieceDownloadSequence = newSeqWith(numOfPieces, iter.next())
  # optional: randomize the order of pieces
  # not sure if this is such a great idea when streaming content
  # Rng.instance.shuffle(pieceDownloadSequence)

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
    blockIter: Iter[int].empty(),
    pieceIndex: 0,
    queue: queue,
    trackedFutures: TrackedFutures(),
  ).success

proc getNewBlockIterator(piece: TorrentPiece): Iter[int] =
  Iter[int].new(piece.blockIndexStart .. piece.blockIndexEnd)

func numberOfBlocks(piece: TorrentPiece): int =
  piece.blockIndexEnd - piece.blockIndexStart + 1

func numberOfBlocksInPiece*(self: TorrentDownloader, pieceIndex: int): ?!int =
  if pieceIndex < 0 or pieceIndex >= self.numberOfPieces:
    return failure("Invalid piece index")
  let piece = self.pieces[pieceIndex]
  success(piece.numberOfBlocks)

proc getNewBlocksInPieceIterator*(
    self: TorrentDownloader, pieceIndex: int
): ?!Iter[int] =
  if pieceIndex < 0 or pieceIndex >= self.numberOfPieces:
    return failure("Invalid piece index")
  let piece = self.pieces[pieceIndex]
  success(piece.getNewBlockIterator())

proc getNewPieceIterator*(self: TorrentDownloader): Iter[int] =
  Iter[int].new(0 ..< self.numberOfPieces)

# proc getNewBlocksPerPieceIterator*(self: TorrentDownloader): Iter[int] =
#   Iter[int].new(0 ..< self.numberOfBlocksPerPiece)

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

proc validate(piece: TorrentPiece, blocks: seq[Block]): ?!void {.raises: [].} =
  var pieceHashCtx: sha1
  pieceHashCtx.init()

  for blk in blocks:
    pieceHashCtx.update(blk.data)

  let computedPieceHash = pieceHashCtx.finish()

  if (computedPieceHash != piece.pieceHash):
    return failure("Piece verification failed")

  success()

proc allBlocksFinished(futs: seq[Future[?!Block]]): seq[?!Block] {.raises: [].} =
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
  let blockIter = piece.getNewBlockIterator()
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

proc fetchPiece(
    self: TorrentDownloader, piece: TorrentPiece
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let treeCid = self.codexManifest.treeCid
  let blockIter = piece.getNewBlockIterator()
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

proc downloadPieces*(self: TorrentDownloader): Future[void] {.async: (raises: []).} =
  try:
    while not self.queue.empty:
      let piece = self.queue.popFirstNoWait()
      trace "Downloading piece", pieceIndex = piece.pieceIndex
      if err =? (await self.fetchPiece(piece)).errorOption:
        error "Could not fetch piece", err = err.msg
        # add the piece to the end of the queue
        # to try to fetch the piece again
        self.queue.addLastNoWait(piece)
        continue
      else:
        # piece fetched and validated successfully
        # mark it as ready
        trace "Piece fetched and validated", pieceIndex = piece.pieceIndex
        piece.handle.complete()
      await sleepAsync(1.millis)
  except CancelledError:
    trace "Downloading pieces cancelled"
  except AsyncQueueFullError as e:
    error "Queue is full", error = e.msg
  except AsyncQueueEmptyError as e:
    error "Trying to pop from empty queue", error = e.msg
  finally:
    await noCancel self.cancel()

# proc downloadPieces*(self: TorrentDownloader): Future[?!void] {.async: (raises: []).} =
#   try:
#     while not self.queue.empty:
#       let piece = self.queue.popFirstNoWait()
#       if err =? (await self.fetchPiece(piece)).errorOption:
#         error "Could not fetch piece", err = err.msg
#         # add the piece to the end of the queue
#         # to try to fetch the piece again
#         self.queue.addLastNoWait(piece)
#         continue
#       else:
#         # piece fetched and validated successfully
#         # mark it as ready
#         piece.handle.complete()
#       await sleepAsync(1.millis)
#   except CancelledError:
#     trace "Downloading pieces cancelled"
#   except AsyncQueueFullError as e:
#     error "Queue is full", error = e.msg
#     return failure e
#   except AsyncQueueEmptyError as e:
#     error "Trying to pop from empty queue", error = e.msg
#     return failure e
#   finally:
#     await noCancel self.cancel()
#   success()

proc getNext*(
    self: TorrentDownloader
): Future[?!(int, seq[byte])] {.async: (raises: []).} =
  try:
    if self.pieceIndex == -1:
      return success((-1, newSeq[byte]()))
    if self.blockIter.finished:
      trace "Waiting for piece", pieceIndex = self.pieceIndex
      self.pieceIndex = await self.waitForNextPiece()
      trace "Got piece", pieceIndex = self.pieceIndex
      if self.pieceIndex == -1:
        return success((-1, newSeq[byte]()))
      else:
        let piece = self.pieces[self.pieceIndex]
        self.blockIter = piece.getNewBlockIterator()
    let blockIndex = self.blockIter.next()
    if blockIndex == self.codexManifest.blocksCount - 1:
      self.pieceIndex = -1
    let address = BlockAddress.init(self.codexManifest.treeCid, blockIndex)
    without blk =? (await self.networkStore.localStore.getBlock(address)), err:
      error "Could not get block from local store", error = err.msg
      return failure("Could not get block from local store: " & err.msg)
    success((blockIndex, blk.data))
  except CancelledError:
    trace "Getting next block from downloader cancelled"
    return success((-1, newSeq[byte]()))
  except CatchableError as e:
    warn "Could not get block from local store", error = e.msg
    return failure("Could not get block from local store: " & e.msg)

proc finished*(self: TorrentDownloader): bool =
  self.pieceIndex == -1

proc start*(self: TorrentDownloader) =
  self.trackedFutures.track(self.downloadPieces())

proc stop*(self: TorrentDownloader) {.async.} =
  self.pieceIndex = -1
  await noCancel self.cancel()
  await noCancel self.trackedFutures.cancelTracked()

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
