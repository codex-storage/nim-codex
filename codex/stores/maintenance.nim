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
import ../utils/trackedfutures
import ../clock
import ../logutils
import ../systemclock

logScope:
  topics = "codex maintenance"

const
  DefaultDefaultExpiry* = 24.hours
  DefaultMaintenanceInterval* = 5.minutes

  TimestampUpdateCycle* = 1000
  ## Update timestamp after deleting a block that's index
  ## is a multiple of this number. The lower the number 
  ## the update is more frequent.
  ##
 
  DefaultRestartDelay* = 15.minutes
  ## If no progress was observed for this amount of time
  ## we're going to restart deletion of the dataset
  ##

type
  DatasetMaintainer* = ref object of RootObj
    blockStore: BlockStore
    metaDs: TypedDatastore
    interval: Duration
    defaultExpiry: Duration
    restartDelay: Duration
    timer: Timer
    clock: Clock
    trackedFutures: TrackedFutures
 

  DatasetMetadata* {.serialize.} = object
    ## Represents metadata for a tracked dataset. Field `maintenanceTimestamp`
    ## reflect last update from the maintance routine
    ## 
    expiry*: SecondsSince1970
    manifestsCids*: seq[Cid]
    maintenanceTimestamp*: SecondsSince1970

  MissingKey* = object of CodexError

proc new*(
    T: type DatasetMaintainer,
    blockStore: BlockStore,
    metaDs: Datastore,
    defaultExpiry = DefaultDefaultExpiry,
    interval = DefaultMaintenanceInterval,
    restartDelay = DefaultRestartDelay,
    timer = Timer.new(),
    clock: Clock = SystemClock.new(),
    trackedFutures = TrackedFutures.new()
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
    restartDelay: restartDelay,
    timer: timer,
    clock: clock,
    trackedFutures: trackedFutures)

proc encode(t: DatasetMetadata): seq[byte] = serializer.toJson(t).toBytes()
proc decode(T: type DatasetMetadata, bytes: seq[byte]): ?!T = T.fromJson(bytes)

proc trackExpiry*(
  self: DatasetMaintainer,
  treeCid: Cid,
  expiry: SecondsSince1970,
  manifestsCids: seq[Cid]
): Future[?!void] {.async.} =
  # Starts tracking expiry of a given dataset
  #

  trace "Tracking an expiry of a dataset", treeCid, expiry

  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  proc modifyFn(maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
    var md: DatasetMetadata

    if currDatasetMd =? maybeCurrDatasetMd:
      md.expiry = max(currDatasetMd.expiry, expiry)

      md.manifestsCids = (currDatasetMd.manifestsCids & manifestsCids).deduplicate
      md.maintenanceTimestamp = currDatasetMd.maintenanceTimestamp
    else:
      md.expiry = expiry
      md.manifestsCids = manifestsCids
      md.maintenanceTimestamp = 0

    md.some

  await modify[DatasetMetadata](self.metaDs, key, modifyFn)

proc trackExpiry*(
  self: DatasetMaintainer,
  treeCid: Cid,
  manifestsCids: seq[Cid]
): Future[?!void] {.async.} =
  await self.trackExpiry(treeCid, self.clock.now + self.defaultExpiry.seconds, manifestsCids)

proc trackExpiry*(
  self: DatasetMaintainer,
  cid: Cid,
  manifestsCids: seq[Cid]
): Future[?!void] {.async.} =
  await self.trackExpiry(cid, self.clock.now + self.defaultExpiry.seconds, manifestsCids)

proc findLeavesCount*(
  self: DatasetMaintainer,
  treeCid: Cid
): Future[?!Natural] {.async.} =
  ## Find out how many leaves are stored for a tree (visible for tests)
  ## 
  
  proc bisect(startIdx: Natural, endIdx: Natural): Future[?!Natural] {.async.} =
    if startIdx < endIdx:
      let midIdx = startIdx + (endIdx - startIdx) div 2.Natural

      without leafPresent =? (await self.blockStore.hasCidAndProof(treeCid, midIdx)), err:
        return failure(err)

      if leafPresent:
        return await bisect(midIdx + 1.Natural, endIdx)
      else:
        return await bisect(startIdx, midIdx)
    else:
      return success(startIdx)

  return await bisect(Natural.low, Natural.high)

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

  proc modifyFn(maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
    if currDatasetMd =? maybeCurrDatasetMd:
      let datasetMd = DatasetMetadata(
        expiry: max(currDatasetMd.expiry, minExpiry),
        manifestsCids: currDatasetMd.manifestsCids,
        maintenanceTimestamp: currDatasetMd.maintenanceTimestamp
      )
      return datasetMd.some
    else:
      raise newException(CatchableError, "DatasetMetadata for treeCid " & $treeCid & " not found")

  await modify[DatasetMetadata](self.metaDs, key, modifyFn)

proc updateTimestamp*(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[?!void] {.async.} =
  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  var datasetMd = datasetMd
  datasetMd.maintenanceTimestamp = self.clock.now

  proc modifyFn(maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
      if currDatasetMd =? maybeCurrDatasetMd:
        if currDatasetMd.expiry != datasetMd.expiry or currDatasetMd.manifestsCids != datasetMd.manifestsCids:
          raise newException(CatchableError, "Change in expiry detected, interrupting maintenance for dataset with treeCid " & $treeCid)

        datasetMd.some
      else:
        raise newException(CatchableError, "Metadata for dataset with treeCid " & $treeCid & " not found")

  await self.metaDs.modify(key, modifyFn)

proc deleteDatasetMetadata(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[?!void] {.async.} =
  without key =? createDatasetMetadataKey(treeCid), err:
    return failure(err)

  proc modifyFn(maybeCurrDatasetMd: ?DatasetMetadata): Future[?DatasetMetadata] {.async.} =
      if currDatasetMd =? maybeCurrDatasetMd:
        if currDatasetMd.expiry != datasetMd.expiry or currDatasetMd.manifestsCids != datasetMd.manifestsCids:
          raise newException(CatchableError, "Change in expiry detected, interrupting maintenance for dataset with treeCid " & $treeCid)

        DatasetMetadata.none
      else:
        raise newException(CatchableError, "Metadata for dataset with treeCid " & $treeCid & " not found")

  await self.metaDs.modify(key, modifyFn)

proc deleteDataset(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[?!void] {.async.} =
  logScope:
    treeCid = treeCid
    manifestsCids = datasetMd.manifestsCids

  if err =? (await self.updateTimestamp(treeCid, datasetMd)).errorOption:
    return failure(err)

  without leavesCount =? (await self.findLeavesCount(treeCid)), err:
    return failure(err)

  if leavesCount == 0:
    trace "No leaves/blocks found to delete"
    return success()

  trace "Starting to delete leaves/blocks", leavesCount

  var index = leavesCount

  while index > 0:
    index.dec

    if err =? (await self.blockStore.delBlock(treeCid, index)).errorOption:
      error "Error deleting a block", msg = err.msg, index
  
    await sleepAsync(1.millis) # cooperative scheduling

    if (index mod TimestampUpdateCycle) == 0:
      if err =? (await self.updateTimestamp(treeCid, datasetMd)).errorOption:
        return failure(err)
  
  trace "Finished deleting leaves/blocks", leavesCount

  for manifestCid in datasetMd.manifestsCids:
    if err =? (await self.blockStore.delBlock(manifestCid)).errorOption:
      error "Error deleting manifest", cid = manifestCid
  
  if err =? (await self.deleteDatasetMetadata(treeCid, datasetMd)).errorOption:
    return failure(err)
  else:
    return success()

proc superviseDatasetDeletion(self: DatasetMaintainer, treeCid: Cid, datasetMd: DatasetMetadata): Future[void] {.async.} =
  logScope:
    treeCid = treeCid
    manifestsCids = datasetMd.manifestsCids
    expiry = datasetMd.expiry

  try:
    if err =? (await self.deleteDataset(treeCid, datasetMd)).errorOption:
      error "Error occurred during deletion of a dataset", msg = err.msg
    else:
      trace "Dataset deletion complete"
  except CancelledError as err:
    raise err
  except CatchableError as err:
    error "Unexpected error during dataset deletion", msg = err.msg, treeCid = treeCid

proc listDatasetMetadata*(
  self: DatasetMaintainer
): Future[?!AsyncIter[(Cid, DatasetMetadata)]] {.async.} =
  without queryKey =? createDatasetMetadataQueryKey(), err:
    return failure(err)

  let mdQuery = Query.init(queryKey)

  without queryIter =? await query[DatasetMetadata](self.metaDs, mdQuery), err:
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
        (datasetMd.maintenanceTimestamp + self.restartDelay.seconds < self.clock.now):
      asyncSpawn self.superviseDatasetDeletion(treeCid, datasetMd).track(self)
    else:
      trace "Item either not expired or expired but already in maintenance", treeCid, expiry = datasetMd.expiry, timestamp = datasetMd.maintenanceTimestamp
  success()

proc start*(self: DatasetMaintainer) =
  proc onTimer(): Future[void] {.async.} =
    try:
      if err =? (await self.checkDatasets()).errorOption:
        error "Error when checking datasets", msg = err.msg
    except CancelledError as err:
      raise err
    except CatchableError as err:
      error "Error when checking datasets", msg = err.msg

  if self.interval.seconds > 0:
    self.timer.start(onTimer, self.interval)

proc stop*(self: DatasetMaintainer): Future[void] {.async.} =
  await self.timer.stop()
  await self.trackedFutures.cancelTracked()
