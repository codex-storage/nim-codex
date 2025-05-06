## Nim-Codex
## Copyright (c) 2021-2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/chronos
import pkg/libbacktrace
import pkg/questionable
import pkg/questionable/results
# import pkg/stew/results as stew_results # Removed deprecated import

import ../blocktype as bt
# import ./asyncstreamwrapper # No longer needed
import ./storestream
import ./seekablestream
import ../logutils
import ../stores
import ../manifest

logScope:
  topics = "codex rangestream"

type
  RangeStream* = ref object of SeekableStream
    store: BlockStore
    manifest: Manifest
    streamStartPos: int # Start position in original dataset
    streamLength: int   # Length of the streamed range
    currentPos: int     # Current position relative to streamStartPos (0 to streamLength-1)
    leftToProcess: int  # Bytes left to process from the stream
    storeStream: StoreStream # Underlying stream for reading data
    pad: bool
  
proc getBlocksForRange(
  self: RangeStream,
  offset: int, 
  length: int
): Future[?!seq[int]] {.async.} =
  ## Get the block indices needed to satisfy a range request
  ## Note: This function seems unused within RangeStream itself.
  ## Keeping it for now in case it's used externally.
  let 
    blockSize = self.manifest.blockSize.int
    firstBlock = offset div blockSize
    lastBlock = min((offset + length - 1) div blockSize, self.manifest.blocksCount - 1)
    
  var blockIndices: seq[int] = @[]
  for i in firstBlock..lastBlock:
    blockIndices.add(i)
    
  return success(blockIndices)

proc new*(
  T: type RangeStream,
  store: BlockStore,
  manifest: Manifest,
  startPos: int,
  length: int,
  pad: bool = false
): RangeStream =
  ## Create a range stream that efficiently retrieves only the necessary blocks
  ## for the requested byte range
  
  let stream = RangeStream(
    store: store,
    manifest: manifest,
    streamStartPos: startPos,
    streamLength: length,
    currentPos: 0,
    leftToProcess: length,
    storeStream: nil, # Initialize lazily
    pad: pad
  )
  
  # Initialize the base LPStream object
  stream.initStream()
  
  return stream

method atEof*(self: RangeStream): bool {.raises: [].} =
  self.leftToProcess <= 0

# Helper proc to initialize the underlying storeStream if needed
proc ensureStoreStream(self: RangeStream) =
  if self.storeStream.isNil:
    self.storeStream = StoreStream.new(self.store, self.manifest, self.pad)
    # Set initial position
    self.storeStream.setPos(self.streamStartPos + self.currentPos) # Start at current absolute position
    debug "RangeStream initialized underlying StoreStream", startPos=self.streamStartPos, currentPos=self.currentPos, storeStreamPos=self.storeStream.offset

method read*(
  self: RangeStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]), base.} =
  ## Read bytes from the specified range within the underlying data.
  
  if self.atEof:
    return 0

  # Ensure underlying stream is ready
  self.ensureStoreStream()

  # Read only as many bytes as needed for the range
  let bytesToRead = min(nbytes, self.leftToProcess)
  if bytesToRead == 0:
    return 0

  var readBytes = 0
  try:
    # Use StoreStream's async readOnce
    readBytes = await self.storeStream.readOnce(pbytes, bytesToRead)
    trace "RangeStream read bytes", got=readBytes, requested=bytesToRead, left=self.leftToProcess-readBytes
  except LPStreamEOFError:
    # StoreStream reached EOF unexpectedly before range end? Log and treat as 0 bytes read for the range.
    warn "StoreStream EOF encountered while reading range", requested=bytesToRead, got=0, rangeLeft=self.leftToProcess
    readBytes = 0 
  except LPStreamError as exc:
    warn "StoreStream error while reading range", msg=exc.msg, requested=bytesToRead, rangeLeft=self.leftToProcess
    raise exc

  if readBytes > 0:
    self.currentPos += readBytes
    self.leftToProcess -= readBytes
  elif self.leftToProcess > 0:
    # If readOnce returned 0 but we still expected bytes, it's effectively EOF for the range
    debug "RangeStream read 0 bytes, marking as EOF", left=self.leftToProcess
    self.leftToProcess = 0 # Mark as EOF

  return readBytes

method close*(
  self: RangeStream
): Future[void] {.async: (raises: [])} =
  ## Close the RangeStream and its underlying StoreStream if initialized.
  trace "Closing RangeStream", currentPos=self.currentPos, left=self.leftToProcess
  if not self.storeStream.isNil:
    await self.storeStream.close() # Use the async close
    self.storeStream = nil # Clear the reference
  # Call base close implementation
  await procCall LPStream(self).closeImpl()

method readOnce*(
  self: RangeStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError])} =
  # Delegate to the main read method
  return await self.read(pbytes, nbytes)

method write*(
  self: RangeStream, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError])} =
  # Range streams are read-only
  raise newException(LPStreamError, "RangeStream is read-only")

method getPosition*(self: RangeStream): int {.base.} =
  ## Get the current position within the defined range (0 to streamLength-1)
  return self.currentPos

method setPos*(self: RangeStream, pos: int): bool {.base.} = # No longer async
  ## Set the position within the defined range (0 to streamLength-1)
  
  # Validate position is within the allowed range [0, streamLength)
  if pos < 0 or pos >= self.streamLength:
    warn "Attempted to seek outside RangeStream bounds", requested=pos, length=self.streamLength
    return false
    
  # Ensure underlying stream is ready
  self.ensureStoreStream()
  
  # Calculate absolute position in the original dataset
  let absolutePos = self.streamStartPos + pos
  
  # Set position in underlying StoreStream (synchronous)
  self.storeStream.setPos(absolutePos) 
  
  # Update RangeStream state
  self.currentPos = pos
  self.leftToProcess = self.streamLength - pos
  
  debug "RangeStream position set", rangePos=pos, absPos=absolutePos, left=self.leftToProcess
  return true

method truncate*(self: RangeStream, size: int): Future[bool] {.async: (raises: [CancelledError, LPStreamError]), base.} =
  # Range streams are read-only
  raise newException(LPStreamError, "RangeStream is read-only")
  # return false # Previous behavior

method getLengthSync*(self: RangeStream): int {.base.} =
  ## Get the total length of the defined range.
  return self.streamLength 