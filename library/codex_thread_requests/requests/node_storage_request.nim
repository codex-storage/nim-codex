{.push raises: [].}

## This file contains the node storage request.
## 4 operations are available:
## - LIST: list all manifests stored in the node.
## - DELETE: Deletes either a single block or an entire dataset from the local node.
## - FETCH: download a file from the network to the local node.
## - SPACE: get the amount of space used by the local node.
## - EXISTS: check the existence of a cid in a node (local store).

import std/[options]
import chronos
import chronicles
import libp2p/stream/[lpstream]
import serde/json as serde
import ../../alloc
import ../../../codex/units
import ../../../codex/manifest
import ../../../codex/stores/repostore

from ../../../codex/codex import CodexServer, node, repoStore
from ../../../codex/node import
  iterateManifests, fetchManifest, fetchDatasetAsyncTask, delete, hasLocalBlock
from libp2p import Cid, init, `$`

logScope:
  topics = "codexlib codexlibstorage"

type NodeStorageMsgType* = enum
  LIST
  DELETE
  FETCH
  SPACE
  EXISTS

type NodeStorageRequest* = object
  operation: NodeStorageMsgType
  cid: cstring

type StorageSpace = object
  totalBlocks* {.serialize.}: Natural
  quotaMaxBytes* {.serialize.}: NBytes
  quotaUsedBytes* {.serialize.}: NBytes
  quotaReservedBytes* {.serialize.}: NBytes

proc createShared*(
    T: type NodeStorageRequest, op: NodeStorageMsgType, cid: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()

  return ret

proc destroyShared(self: ptr NodeStorageRequest) =
  deallocShared(self[].cid)
  deallocShared(self)

type ManifestWithCid = object
  cid {.serialize.}: string
  manifest {.serialize.}: Manifest

proc list(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  var manifests = newSeq[ManifestWithCid]()
  proc onManifest(cid: Cid, manifest: Manifest) {.raises: [], gcsafe.} =
    manifests.add(ManifestWithCid(cid: $cid, manifest: manifest))

  try:
    let node = codex[].node
    await node.iterateManifests(onManifest)
  except CancelledError:
    return err("Failed to list manifests: cancelled operation.")
  except CatchableError as err:
    return err("Failed to list manifest: : " & err.msg)

  return ok(serde.toJson(manifests))

proc delete(
    codex: ptr CodexServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to delete the data: cannot parse cid: " & $cCid)

  let node = codex[].node
  try:
    let res = await node.delete(cid.get())
    if res.isErr:
      return err("Failed to delete the data: " & res.error.msg)
  except CancelledError:
    return err("Failed to delete the data: cancelled operation.")
  except CatchableError as err:
    return err("Failed to delete the data: " & err.msg)

  return ok("")

proc fetch(
    codex: ptr CodexServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to fetch the data: cannot parse cid: " & $cCid)

  try:
    let node = codex[].node
    let manifest = await node.fetchManifest(cid.get())
    if manifest.isErr:
      return err("Failed to fetch the data: " & manifest.error.msg)

    node.fetchDatasetAsyncTask(manifest.get())

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch the data: download cancelled.")

proc space(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let repoStore = codex[].repoStore
  let space = StorageSpace(
    totalBlocks: repoStore.totalBlocks,
    quotaMaxBytes: repoStore.quotaMaxBytes,
    quotaUsedBytes: repoStore.quotaUsedBytes,
    quotaReservedBytes: repoStore.quotaReservedBytes,
  )
  return ok(serde.toJson(space))

proc exists(
    codex: ptr CodexServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to check the data existence: cannot parse cid: " & $cCid)

  try:
    let node = codex[].node
    let exists = await node.hasLocalBlock(cid.get())
    return ok($exists)
  except CancelledError:
    return err("Failed to check the data existence: operation cancelled.")

proc process*(
    self: ptr NodeStorageRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeStorageMsgType.LIST:
    let res = (await list(codex))
    if res.isErr:
      error "Failed to LIST.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.DELETE:
    let res = (await delete(codex, self.cid))
    if res.isErr:
      error "Failed to DELETE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.FETCH:
    let res = (await fetch(codex, self.cid))
    if res.isErr:
      error "Failed to FETCH.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.SPACE:
    let res = (await space(codex))
    if res.isErr:
      error "Failed to SPACE.", error = res.error
      return err($res.error)
  of NodeStorageMsgType.EXISTS:
    let res = (await exists(codex, self.cid))
    if res.isErr:
      error "Failed to EXISTS.", error = res.error
      return err($res.error)
    return res
