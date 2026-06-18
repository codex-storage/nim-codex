## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
import confutils
import codexdht/discv5/spr
import metrics
import ../../logosmetrics
import ../../../storage/conf
import ../../../storage/rest/json
import ../../../storage/node

from ../../../storage/storage import StorageServer, config, node

logScope:
  topics = "libstorage libstorageinfo"

type NodeInfoMsgType* = enum
  REPO
  SPR
  PEERID
  # Not sure this belongs here but for now OK.
  METRICS

type NodeInfoRequest* = object
  operation: NodeInfoMsgType

proc createShared*(T: type NodeInfoRequest, op: NodeInfoMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr NodeInfoRequest) =
  deallocShared(self)

proc getRepo(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($(storage[].config.dataDir))

proc getSpr(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let spr = storage[].node.discovery.dhtRecord
  if spr.isNone:
    return err("Failed to get SPR: no SPR record found.")

  return ok(spr.get.toURI)

proc getPeerId(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($storage[].node.switch.peerInfo.peerId)

proc process*(
    self: ptr NodeInfoRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of REPO:
    let res = (await getRepo(storage))
    if res.isErr:
      error "Failed to get REPO.", error = res.error
      return err($res.error)
    return res
  of SPR:
    let res = (await getSpr(storage))
    if res.isErr:
      error "Failed to get SPR.", error = res.error
      return err($res.error)
    return res
  of PEERID:
    let res = (await getPeerId(storage))
    if res.isErr:
      error "Failed to get PEERID.", error = res.error
      return err($res.error)
    return res
  of METRICS:
    # We're running on the main thread so it should be fine to access
    # defaultRegistry.
    {.cast(gcsafe).}:
      # Excludes nim_runtime_info as dumpHeapInstances seems to be returning
      # an infinite number of objects.
      # FIXME figure out what's going on and add this back.
      return ok($defaultRegistry.toJson(exclude = @["nim_runtime_info"]))
