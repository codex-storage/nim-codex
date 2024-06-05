## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Store maintenance module
## Looks for and removes expired blocks from blockstores.

import std/sequtils

import pkg/chronos
import pkg/chronicles
import pkg/libp2p/cid
import pkg/serde/json
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ./keyutils
import ./queryiterhelper
import ../utils/timer
import ../utils/asynciter
import ../utils/json
import ../clock
import ../logutils
import ../systemclock


logScope:
  topics = "codex maintenance"

const
  DefaultDefaultExpiry* = 24.hours
  DefaultMaintenanceInterval* = 5.minutes
  DefaultBatchSize* = 1000

  # if no progress was observed for this amount of time
  # we're going to retry deletion of the dataset
  DefaultRetryDelay* = 15.minutes

type
  DatasetMaintainer* = ref object of RootObj
    blockStore: BlockStore
    metaDs: TypedDatastore
    interval: Duration
    defaultExpiry: Duration
    batchSize: int
    retryDelay: Duration
    timer: Timer
    clock: Clock

  Checkpoint* {.serialize.} = object
    timestamp*: SecondsSince1970
    progress*: Natural

  DatasetMetadata* {.serialize.} = object
    expiry*: SecondsSince1970
    leavesCount*: Natural
    manifestsCids*: seq[Cid]
    checkpoint*: Checkpoint

  MissingKey* = object of CodexError

proc new*(
    T: type DatasetMaintainer,
    blockStore: BlockStore,
    metaDs: Datastore,
    defaultExpiry = DefaultDefaultExpiry,
    interval = DefaultMaintenanceInterval,
    batchSize = DefaultBatchSize,
    retryDelay = DefaultRetryDelay,
    timer = Timer.new(),
    clock: Clock = SystemClock.new()
): DatasetMaintainer =
  ## Create new DatasetMaintainer instance
  ##
  ## Call `start` to begin looking for for expired blocks
  ##
  DatasetMaintainer(
    blockStore: blockStore,
    metaDs: TypedDatastore.init(metaDs),
    defaultExpiry: defaultExpiry,
    interval: interval,
    batchSize: batchSize,
    retryDelay: retryDelay,
    timer: timer,
    clock: clock)

proc encode(t: Checkpoint): seq[byte] = serializer.toJson(t).toBytes()
proc decode(T: type Checkpoint, bytes: seq[byte]): ?!T = T.fromJson(bytes)

proc encode(t: DatasetMetadata): seq[byte] = serializer.toJson(t).toBytes()
proc decode(T: type DatasetMetadata, bytes: seq[byte]): ?!T = T.fromJson(bytes)

proc trackExpiry*(
  self: DatasetMaintainer,
  treeCid: Cid,
  leavesCount: Natural,
  expiry: SecondsSince1970,
  manifestsCids: seq[Cid] = @[]
): Future[?!void] {.async.} =
  # Starts tracking expiry of a given dataset
  #

  trace "Tracking an expiry of a dataset", treeCid, leavesCount, expiry

  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  await modify[DatasetMetadata](self.metaDs, key,
    proc (maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
      var md: DatasetMetadata

      if currDatasetMd =? maybeCurrDatasetMd:
        md.expiry = max(currDatasetMd.expiry, expiry)

        if currDatasetMd.leavesCount != leavesCount:
          raise newException(CatchableError, "DatasetMetadata for treeCid " & $treeCid & " is already stored with leavesCount " &
            $currDatasetMd.leavesCount & ", cannot override it with leavesCount " & $leavesCount)

        md.leavesCount = leavesCount
        md.manifestsCids = (currDatasetMd.manifestsCids & manifestsCids).deduplicate
        md.checkpoint = Checkpoint(progress: 0, timestamp: 0)
      else:
        md.expiry = expiry
        md.leavesCount = leavesCount
        md.manifestsCids = manifestsCids
        md.checkpoint = Checkpoint(progress: 0, timestamp: 0)

      md.some
  )

proc trackExpiry*(
  self: DatasetMaintainer,
  treeCid: Cid,
  leavesCount: Natural,
  manifestsCids: seq[Cid] = @[]
): Future[?!void] {.async.} =
  await self.trackExpiry(treeCid, leavesCount, self.clock.now + self.defaultExpiry.seconds, manifestsCids)

proc trackExpiry*(
  self: DatasetMaintainer,
  cid: Cid,
  manifestsCids: seq[Cid] = @[]
): Future[?!void] {.async.} =
  await self.trackExpiry(cid, 0, self.clock.now + self.defaultExpiry.seconds, manifestsCids)

proc ensureExpiry*(
  self: DatasetMaintainer,
  treeCid: Cid,
  minExpiry: SecondsSince1970): Future[?!void] {.async.} =
  ## Sets the dataset expiry to a max of two values: current expiry and `minExpiry`,
  ## if a dataset for given `treeCid` is not currently tracked a CatchableError is thrown
  ##

  trace "Updating a dataset expiry", treeCid, minExpiry

  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  await modify[DatasetMetadata](self.metaDs, key,
    proc (maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
      if currDatasetMd =? maybeCurrDatasetMd:
        let datasetMd = DatasetMetadata(
          expiry: max(currDatasetMd.expiry, minExpiry),
          leavesCount: currDatasetMd.leavesCount,
          manifestsCids: currDatasetMd.manifestsCids,
          checkpoint: currDatasetMd.checkpoint
        )
        return datasetMd.some
      else:
        raise newException(CatchableError, "DatasetMetadata for treeCid " & $treeCid & " not found")
  )


proc recordCheckpoint*(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[?!void] {.async.} =
  # Saves progress or deletes dataset metadata if progress > leavesCount
  #

  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  await self.metaDs.modify(key,
    proc (maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
      if currDatasetMd =? maybeCurrDatasetMd:
        if currDatasetMd.expiry != datasetMd.expiry or currDatasetMd.manifestsCids != datasetMd.manifestsCids:
          raise newException(CatchableError, "Change in expiry detected, interrupting maintenance for dataset with treeCid " & $treeCid)

        if currDatasetMd.checkpoint.progress > datasetMd.checkpoint.progress:
          raise newException(CatchableError, "Progress should be increasing only, treeCid " & $treeCid)

        if currDatasetMd.leavesCount <= datasetMd.checkpoint.progress:
          DatasetMetadata.none
        else:
          datasetMd.some
      else:
        raise newException(CatchableError, "Metadata for dataset with treeCid " & $treeCid & " not found")
  )

proc deleteBatch(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[?!void] {.async.} =
  var datasetMd = datasetMd

  datasetMd.checkpoint.timestamp = self.clock.now

  if err =? (await self.recordCheckpoint(treeCid, datasetMd)).errorOption:
    return failure(err)

  logScope:
    treeCid = treeCid
    manifestsCids = datasetMd.manifestsCids
    startingIndex = datasetMd.checkpoint.progress

  trace "Deleting a batch of blocks", size = self.batchSize

  var index = datasetMd.checkpoint.progress
  while (index < datasetMd.checkpoint.progress + self.batchSize) and
          (index < datasetMd.leavesCount):
    if err =? (await self.blockStore.delBlock(treeCid, index)).errorOption:
      error "Error deleting a block", msg = err.msg, index

    index.inc

    await sleepAsync(50.millis) # cooperative scheduling

  if index >= datasetMd.leavesCount:
    trace "All blocks deleted from a dataset", leavesCount = datasetMd.leavesCount

    for manifestCid in datasetMd.manifestsCids:
      if err =? (await self.blockStore.delBlock(manifestCid)).errorOption:
        error "Error deleting manifest", cid = manifestCid

    if err =? (await self.blockStore.delBlock(treeCid)).errorOption:
      error "Error deleting block", cid = treeCid

    if err =? (await self.recordCheckpoint(treeCid, datasetMd)).errorOption:
      return failure(err)

    return success()
  else:
    datasetMd.checkpoint.progress = index
    return await self.deleteBatch(treeCid, datasetMd)

proc superviseDatasetDeletion(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[void] {.async.} =
  logScope:
    treeCid = treeCid
    manifestsCids = datasetMd.manifestsCids
    expiry = datasetMd.expiry
    leavesCount = datasetMd.leavesCount

  try:
    if datasetMd.checkpoint.progress == 0 and datasetMd.checkpoint.timestamp == 0:
      info "Initiating deletion of a dataset"
    else:
      info "Retrying deletion of a dataset", progress = datasetMd.checkpoint.progress, timestamp = datasetMd.checkpoint.timestamp

    if err =? (await self.deleteBatch(treeCid, datasetMd)).errorOption:
      error "Error occurred during deletion of a dataset", msg = err.msg
    else:
      info "Dataset deletion complete"
  except CatchableError as err:
    error "Unexpected error during dataset deletion", msg = err.msg, treeCid = treeCid

proc listDatasetMetadata*(
  self: DatasetMaintainer
): Future[?!AsyncIter[(Cid, DatasetMetadata)]] {.async.} =
  without queryKey =? createDatasetMetadataQueryKey(), err:
    return failure(err)

  without queryIter =? await query[DatasetMetadata](self.metaDs, Query.init(queryKey)), err:
    error "Unable to execute block expirations query", err = err.msg
    return failure(err)

  without asyncQueryIter =? await queryIter.toAsyncIter(), err:
    error "Unable to convert QueryIter to AsyncIter", err = err.msg
    return failure(err)

  let
    filteredIter = await asyncQueryIter.filterSuccess()

    datasetMdIter = await mapFilter[KeyVal[DatasetMetadata], (Cid, DatasetMetadata)](filteredIter,
      proc (kv: KeyVal[DatasetMetadata]): Future[?(Cid, DatasetMetadata)] {.async.} =
        without cid =? Cid.init(kv.key.value).mapFailure, err:
          error "Failed decoding cid", err = err.msg
          return (Cid, DatasetMetadata).none


        (cid, kv.value).some
    )

  success(datasetMdIter)


proc checkDatasets(self: DatasetMaintainer): Future[?!void] {.async.} =
  without iter =? await self.listDatasetMetadata(), err:
    return failure(err)

  for fut in iter:
    let (treeCid, datasetMd) = await fut

    if (datasetMd.expiry < self.clock.now) and
        (datasetMd.checkpoint.timestamp + self.retryDelay.seconds < self.clock.now):
      asyncSpawn self.superviseDatasetDeletion(treeCid, datasetMd)
    else:
      trace "Item either not expired or expired but already in maintenance", treeCid, expiry = datasetMd.expiry, timestamp = datasetMd.checkpoint.timestamp
  success()

proc start*(self: DatasetMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    try:
      if err =? (await self.checkDatasets()).errorOption:
        error "Error when checking datasets", msg = err.msg
    except Exception as exc:
      error "Unexpected error during maintenance", msg = exc.msg

  if self.interval.seconds > 0:
    self.timer.start(onTimer, self.interval)

proc stop*(self: DatasetMaintainer): Future[void] {.async.} =
  await self.timer.stop()
