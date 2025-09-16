## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
import confutils
import ../../../codex/conf

from ../../../codex/codex import CodexServer

type NodeInfoMsgType* = enum
  REPO

type NodeInfoRequest* = object
  operation: NodeInfoMsgType

proc createShared*(
    T: type NodeInfoRequest, op: NodeInfoMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr NodeInfoRequest) =
  deallocShared(self)

proc getRepo(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($(codex[].config.dataDir))

proc process*(
    self: ptr NodeInfoRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of REPO:
    let res = (await getRepo(codex))
    if res.isErr:
      error "INFO failed", error = res.error
      return err($res.error)
    return res

  return ok("")
