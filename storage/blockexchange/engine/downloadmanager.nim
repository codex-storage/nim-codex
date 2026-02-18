## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[tables, sets, options]

import pkg/chronos
import pkg/libp2p
import pkg/questionable

import ../protocol/message
import ../protocol/constants
import ../utils
import ../../blocktype
import ../../logutils

import ./activedownload

export activedownload

logScope:
  topics = "storage downloadmanager"

const
  DefaultBlockRetries* = 100
  DefaultRetryInterval* = 2.seconds

type
  DownloadManager* = ref object of RootObj
    nextDownloadId*: uint64 = 1 # 0 is invalid
    blockRetries*: int
    retryInterval*: Duration
    downloads*: Table[Cid, Table[uint64, ActiveDownload]]
    selectionPolicy*: SelectionPolicy

  DownloadDesc* = object
    cid*: Cid
    blockSize*: uint32
    startIndex*: uint64
    count*: uint64

proc id*(desc: DownloadDesc): Cid =
  desc.cid

proc toDownloadDesc*(
    treeCid: Cid, totalBlocks: uint64, blockSize: uint32
): DownloadDesc =
  DownloadDesc(cid: treeCid, blockSize: blockSize, startIndex: 0, count: totalBlocks)

proc toDownloadDesc*(
    treeCid: Cid, startIndex: uint64, count: uint64, blockSize: uint32
): DownloadDesc =
  DownloadDesc(cid: treeCid, blockSize: blockSize, startIndex: startIndex, count: count)

proc toDownloadDesc*(address: BlockAddress, blockSize: uint32): DownloadDesc =
  DownloadDesc(
    cid: address.treeCid,
    blockSize: blockSize,
    startIndex: address.index.uint64,
    count: 1,
  )

proc getDownload*(self: DownloadManager, treeCid: Cid): Option[ActiveDownload] =
  self.downloads.withValue(treeCid, innerTable):
    for _, download in innerTable[]:
      return some(download)
  return none(ActiveDownload)

proc getDownload*(
    self: DownloadManager, downloadId: uint64, cid: Cid
): Option[ActiveDownload] =
  self.downloads.withValue(cid, innerTable):
    innerTable[].withValue(downloadId, download):
      return some(download[])
  return none(ActiveDownload)

proc cancelDownload*(self: DownloadManager, download: ActiveDownload) =
  download.cancelled = true

  for _, batch in download.pendingBatches:
    if not batch.timeoutFuture.isNil and not batch.timeoutFuture.finished:
      batch.timeoutFuture.cancelSoon()
    if not batch.requestFuture.isNil and not batch.requestFuture.finished:
      batch.requestFuture.cancelSoon()

  for address, req in download.blocks:
    if not req.handle.finished:
      req.handle.fail(newException(CancelledError, "Download cancelled"))
    if not req.opaqueHandle.finished:
      req.opaqueHandle.fail(newException(CancelledError, "Download cancelled"))
  download.blocks.clear()

  if not download.completionFuture.finished:
    download.completionFuture.fail(newException(CancelledError, "Download cancelled"))

  self.downloads.withValue(download.cid, innerTable):
    innerTable[].del(download.id)
    if innerTable[].len == 0:
      self.downloads.del(download.cid)

proc cancelDownload*(self: DownloadManager, cid: Cid) =
  self.downloads.withValue(cid, innerTable):
    var toCancel: seq[ActiveDownload] = @[]
    for _, download in innerTable[]:
      toCancel.add(download)
    for download in toCancel:
      self.cancelDownload(download)

proc releaseDownload*(self: DownloadManager, cid: Cid) =
  self.cancelDownload(cid)

proc releaseDownload*(self: DownloadManager, downloadId: uint64, cid: Cid) =
  let download = self.getDownload(downloadId, cid)
  if download.isSome:
    self.cancelDownload(download.get())

proc getNextBatch*(
    self: DownloadManager, download: ActiveDownload
): Option[tuple[start: uint64, count: uint64]] =
  case self.selectionPolicy
  of spSequential:
    let batch = download.ctx.scheduler.take()
    if batch.isSome:
      return some((start: batch.get().start, count: batch.get().count))

  return none(tuple[start: uint64, count: uint64])

proc startDownload*(
    self: DownloadManager, desc: DownloadDesc, missingBlocks: seq[uint64] = @[]
): ActiveDownload =
  let
    totalBlocks = desc.startIndex + desc.count
    ctx = DownloadContext.new(desc.cid, desc.blockSize, totalBlocks)
    batchSize =
      if desc.blockSize > 0:
        computeBatchSize(desc.blockSize)
      else:
        MinBatchSize

  if missingBlocks.len > 0:
    # use explicit indices directly
    ctx.scheduler.initFromIndices(missingBlocks, batchSize.uint64)
  elif desc.count > batchSize.uint64:
    # this is a large download, more than one batch, use lazy mode
    if desc.startIndex == 0:
      ctx.scheduler.init(desc.count, batchSize.uint64)
    else:
      ctx.scheduler.initRange(desc.startIndex, desc.count, batchSize.uint64)
  else:
    # this is a small range, single batch or less, schedule explicit indices
    var indices: seq[uint64] = @[]
    for i in desc.startIndex ..< desc.startIndex + desc.count:
      indices.add(i)
    ctx.scheduler.initFromIndices(indices, batchSize.uint64)

  let downloadId = self.nextDownloadId
  self.nextDownloadId += 1

  let download = ActiveDownload(
    id: downloadId,
    cid: desc.cid,
    ctx: ctx,
    blocks: initTable[BlockAddress, BlockReq](),
    pendingBatches: initTable[uint64, PendingBatch](),
    inFlightBatches: initTable[PeerId, seq[Future[void]]](),
    exhaustedBlocks: initHashSet[BlockAddress](),
    blockRetries: self.blockRetries,
    retryInterval: self.retryInterval,
    completionFuture:
      Future[?!void].Raising([CancelledError]).init("ActiveDownload.completion"),
  )

  self.downloads.mgetOrPut(desc.cid, initTable[uint64, ActiveDownload]())[downloadId] =
    download

  trace "Started download",
    cid = desc.cid,
    startIndex = desc.startIndex,
    count = desc.count,
    batchSize = batchSize

  return download

proc new*(
    T: type DownloadManager,
    retries = DefaultBlockRetries,
    interval = DefaultRetryInterval,
    selectionPolicy = spSequential,
): DownloadManager =
  DownloadManager(
    blockRetries: retries,
    retryInterval: interval,
    downloads: initTable[Cid, Table[uint64, ActiveDownload]](),
    selectionPolicy: selectionPolicy,
  )
