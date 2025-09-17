## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
# import confutils
import codexdht/discv5/spr
# import ../../../codex/conf
import ../../../codex/rest/json
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

type NodeDebugMsgType* = enum
  DEBUG

type NodeDebugRequest* = object
  operation: NodeDebugMsgType

proc createShared*(T: type NodeDebugRequest, op: NodeDebugMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr NodeDebugRequest) =
  deallocShared(self)

proc getDebug(
    codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let node = codex[].node
  let table = RestRoutingTable.init(node.discovery.protocol.routingTable)

  let json =
    %*{
      "id": $node.switch.peerInfo.peerId,
      "addrs": node.switch.peerInfo.addrs.mapIt($it),
      "spr":
        if node.discovery.dhtRecord.isSome: node.discovery.dhtRecord.get.toURI else: "",
      "announceAddresses": node.discovery.announceAddrs,
      "table": table,
    }

  return ok($json)

proc process*(
    self: ptr NodeDebugRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeDebugMsgType.DEBUG:
    let res = (await getDebug(codex))
    if res.isErr:
      error "DEBUG failed", error = res.error
      return err($res.error)
    return res

  return ok("")
