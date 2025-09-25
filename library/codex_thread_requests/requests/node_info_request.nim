## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
import confutils
import codexdht/discv5/spr
import ../../../codex/conf
import ../../../codex/rest/json
import ../../../codex/node

from ../../../codex/codex import CodexServer, config, node

logScope:
  topics = "codexlib codexlibinfo"

type NodeInfoMsgType* = enum
  REPO
  SPR
  PEERID

type NodeInfoRequest* = object
  operation: NodeInfoMsgType

proc createShared*(T: type NodeInfoRequest, op: NodeInfoMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr NodeInfoRequest) =
  deallocShared(self)

proc getRepo(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($(codex[].config.dataDir))

proc getSpr(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let spr = codex[].node.discovery.dhtRecord
  if spr.isNone:
    return err("Failed to get SPR: no SPR record found.")

  return ok(spr.get.toURI)

proc getPeerId(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($codex[].node.switch.peerInfo.peerId)

proc process*(
    self: ptr NodeInfoRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of REPO:
    let res = (await getRepo(codex))
    if res.isErr:
      error "Failed to get REPO.", error = res.error
      return err($res.error)
    return res
  of SPR:
    let res = (await getSpr(codex))
    if res.isErr:
      error "Failed to get SPR.", error = res.error
      return err($res.error)
    return res
  of PEERID:
    let res = (await getPeerId(codex))
    if res.isErr:
      error "Failed to get PEERID.", error = res.error
      return err($res.error)
    return res

  return ok("")
