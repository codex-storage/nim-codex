## Nim-Codex
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/os
import std/times
import std/strutils
import std/sequtils
import std/sugar
import pkg/chronos
import pkg/libp2p/[cid, multihash]
import pkg/libp2p/stream/lpstream
import pkg/questionable/results
import pkg/stew/byteutils

import ../node
import ../logutils
import ../utils/iter
import ../utils/safeasynciter
import ../utils/trackedfutures
import ../errors
import ../manifest
import ../blocktype
import ../stores/blockstore

import ./tarballs
import ./directorymanifest
import ./decoding

logScope:
  topics = "codex node directorydownloader"

type DirectoryDownloader* = ref object
  node: CodexNodeRef
  queue*: AsyncQueue[seq[byte]]
  finished: bool
  trackedFutures: TrackedFutures

proc printQueue(self: DirectoryDownloader) =
  echo "Queue: ", self.queue.len, " entries"
  for i in 0 ..< self.queue.len:
    echo "Entry ", i, ": ", self.queue[i].len, " bytes"

proc createEntryHeader(
    self: DirectoryDownloader, entry: TarballEntry, basePath: string
): string =
  echo "Creating entry header for ", entry.name
  echo "basePath = ", basePath
  echo "entry = ", entry
  result = newStringOfCap(512)
  result.add(entry.name)
  result.setLen(100)
  # ToDo: read permissions from the TarballEntry
  if entry.kind == ekDirectory:
    result.add("000755 \0") # Dir mode
  else:
    result.add("000644 \0") # File mode
  result.add(toOct(0, 6) & " \0") # Owner's numeric user ID
  result.add(toOct(0, 6) & " \0") # Group's numeric user ID
  result.add(toOct(entry.contentLength, 11) & ' ') # File size
  result.add(toOct(entry.lastModified.toUnix(), 11) & ' ') # Last modified time
  result.add("        ") # Empty checksum for now
  result.setLen(156)
  result.add(ord(entry.kind).char)
  result.setLen(257)
  result.add("ustar\0") # UStar indicator
  result.add(toOct(0, 2)) # UStar version
  result.setLen(329)
  result.add(toOct(0, 6) & "\0 ") # Device major number
  result.add(toOct(0, 6) & "\0 ") # Device minor number
  result.add(basePath)
  result.setLen(512)

  var checksum: int
  for i in 0 ..< result.len:
    checksum += result[i].int

  let checksumStr = toOct(checksum, 6) & '\0'
  for i in 0 ..< checksumStr.len:
    result[148 + i] = checksumStr[i]

proc fetchTarball(
    self: DirectoryDownloader, cid: Cid, basePath = ""
): Future[?!void] {.async: (raises: [CancelledError]).} =
  echo "fetchTarball: ", cid, " basePath = ", basePath
  # we got a Cid - let's check if this is a manifest (can be either
  # a directory or file manifest)
  without isM =? cid.isManifest, err:
    warn "Unable to determine if cid is a manifest"
    return failure("Unable to determine if cid is a manifest")

  if not isM:
    # this is not a manifest, so we can return
    return failure("given cid is not a manifest: " & $cid)

  # get the manifest
  without blk =? await self.node.blockStore.getBlock(cid), err:
    error "Error retrieving manifest block", cid, err = err.msg
    return
      failure("Error retrieving manifest block (cid = " & $cid & "), err = " & err.msg)

  without manifest =? Manifest.decode(blk), err:
    info "Unable to decode as manifest - trying to decode as directory manifest",
      err = err.msg
    # Try if it not a directory manifest
    without manifest =? DirectoryManifest.decode(blk), err:
      error "Unable to decode as directory manifest", err = err.msg
      return failure("Unable to decode as valid manifest (cid = " & $cid & ")")
    # this is a directory manifest
    echo "Decoded directory manifest: ", $manifest
    let dirEntry = TarballEntry(
      kind: ekDirectory,
      name: manifest.name,
      lastModified: getTime(), # ToDo: store actual time in the manifest
      permissions: parseFilePermissions(cast[uint32](0o755)), # same here
      contentLength: 0,
    )
    let header = self.createEntryHeader(dirEntry, basePath)
    echo "header = ", header
    await self.queue.addLast(header.toBytes())
    self.printQueue()
    var entryLength = header.len
    let alignedEntryLength = (entryLength + 511) and not 511 # 512 byte aligned
    if alignedEntryLength - entryLength > 0:
      echo "Adding ", alignedEntryLength - entryLength, " bytes of padding"
      var data = newSeq[byte]()
      data.setLen(alignedEntryLength - entryLength)
      await self.queue.addLast(data)
    self.printQueue()

    for cid in manifest.cids:
      echo "fetching directory content: ", cid
      if err =? (await self.fetchTarball(cid, basePath / manifest.name)).errorOption:
        error "Error fetching directory content",
          cid, path = basePath / manifest.name, err = err.msg
        return failure(
          "Error fetching directory content (cid = " & $cid & "), err = " & err.msg
        )
    echo "fetchTarball[DIR]: ", cid, " basePath = ", basePath, " done"
    return success()

  # this is a regular file (Codex) manifest
  echo "Decoded file manifest: ", $manifest
  let fileEntry = TarballEntry(
    kind: ekNormalFile,
    name: manifest.filename |? "unknown",
    lastModified: getTime(), # ToDo: store actual time in the manifest
    permissions: parseFilePermissions(cast[uint32](0o644)), # same here
    contentLength: manifest.datasetSize.int,
  )
  let header = self.createEntryHeader(fileEntry, basePath)
  await self.queue.addLast(header.toBytes())
  self.printQueue()
  var contentLength = 0

  proc onBatch(
      blocks: seq[Block]
  ): Future[?!void] {.async: (raises: [CancelledError]).} =
    echo "onBatch: ", blocks.len, " blocks"
    for blk in blocks:
      echo "onBatch[blk.data]: ", string.fromBytes(blk.data)
      # await self.queue.addLast(string.fromBytes(blk.data))
      await self.queue.addLast(blk.data)
      self.printQueue()
      contentLength += blk.data.len
      # this can happen if the content was stored with padding
      if contentLength > manifest.datasetSize.int:
        contentLength = manifest.datasetSize.int
      echo "onBatch[contentLength]: ", contentLength
    success()

  await self.node.fetchDatasetAsync(manifest, fetchLocal = true, onBatch = onBatch)

  echo "contentLength: ", contentLength
  echo "manifest.datasetSize.int: ", manifest.datasetSize.int
  if contentLength != manifest.datasetSize.int:
    echo "Warning: entry length mismatch, expected ",
      manifest.datasetSize.int, " got ", contentLength

  let entryLength = header.len + contentLength
  let alignedEntryLength = (entryLength + 511) and not 511 # 512 byte aligned
  if alignedEntryLength - entryLength > 0:
    echo "Adding ", alignedEntryLength - entryLength, " bytes of padding"
    var data = newSeq[byte]()
    echo "alignedEntryLength: ", alignedEntryLength
    echo "entryLength: ", entryLength
    echo "alignedEntryLength - entryLength: ", alignedEntryLength - entryLength
    data.setLen(alignedEntryLength - entryLength)
    echo "data.len: ", data.len
    await self.queue.addLast(data)
    self.printQueue()
  echo "fetchTarball: ", cid, " basePath = ", basePath, " done"
  return success()

proc streamDirectory(
    self: DirectoryDownloader, cid: Cid
): Future[void] {.async: (raises: []).} =
  try:
    if err =? (await self.fetchTarball(cid, basePath = "")).errorOption:
      error "Error fetching directory content", cid, err = err.msg
      return
    # Two consecutive zero-filled records at end
    var data = newSeq[byte]()
    data.setLen(1024)
    await self.queue.addLast(data)
    self.printQueue()
    # mark the end of the stream
    self.finished = true
    echo "streamDirectory: ", cid, " done"
  except CancelledError:
    info "Streaming directory cancelled:", cid

###########################################################################
# Public API
###########################################################################

proc start*(self: DirectoryDownloader, cid: Cid) =
  ## Starts streaming the directory content
  self.trackedFutures.track(self.streamDirectory(cid))

proc stop*(self: DirectoryDownloader) {.async: (raises: []).} =
  await noCancel self.trackedFutures.cancelTracked()

proc getNext*(
    self: DirectoryDownloader
): Future[seq[byte]] {.async: (raises: [CancelledError]).} =
  ## Returns the next entry from the queue
  echo "getNext: ", self.queue.len, " entries in queue"
  if (self.queue.len == 0 and self.finished):
    return @[]
  echo "getNext[2]: ", self.queue.len, " entries in queue"
  let chunk = await self.queue.popFirst()
  echo "getNext: ", chunk.len, " bytes"
  return chunk

proc newDirectoryDownloader*(node: CodexNodeRef): DirectoryDownloader =
  ## Creates a new DirectoryDownloader instance
  DirectoryDownloader(
    node: node,
    queue: newAsyncQueue[seq[byte]](),
    finished: false,
    trackedFutures: TrackedFutures(),
  )
