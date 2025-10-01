{.push raises: [].}

## This file contains the node storage request.

import std/[options]
import chronos
import chronicles
import libp2p/stream/[lpstream]
import serde/json as serde
import ../../alloc
import ../../../codex/manifest

from ../../../codex/codex import CodexServer, node
from ../../../codex/node import iterateManifests
from libp2p import Cid, init, `$`

logScope:
  topics = "codexlib codexlibstorage"

type NodeStorageMsgType* = enum
  LIST
  DELETE
  FETCH
  SPACE

type NodeStorageRequest* = object
  operation: NodeStorageMsgType
  cid: cstring

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
    codex: ptr CodexServer, cid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  return err("DELETE operation not implemented yet.")

proc fetch(
    codex: ptr CodexServer, cid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  return err("FETCH operation not implemented yet.")

proc space(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return err("SPACE operation not implemented yet.")

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
    return res
