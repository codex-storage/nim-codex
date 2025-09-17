## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
import codexdht/discv5/spr
import ../../alloc
import ../../../codex/conf
import ../../../codex/rest/json
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

type NodeDebugMsgType* = enum
  DEBUG
  PEER

type NodeDebugRequest* = object
  operation: NodeDebugMsgType
  peerId: cstring

proc createShared*(
    T: type NodeDebugRequest, op: NodeDebugMsgType, peerId: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  return ret

proc destroyShared(self: ptr NodeDebugRequest) =
  deallocShared(self[].peerId)
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

proc getPeer(
    codex: ptr CodexServer, peerId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  when codex_enable_api_debug_peers:
    let node = codex[].node
    let res = PeerId.init($peerId)
    if res.isErr:
      return err("Invalid peer ID " & $peerId & ": " & $res.error())

    let id = res.get()

    try:
      let peerRecord = await node.findPeer(id)
      if peerRecord.isNone:
        return err("Peer not found")

      return ok($ %RestPeerRecord.init(peerRecord.get()))
    except CancelledError:
      return err("Operation cancelled")
    except CatchableError as e:
      return err("Error when finding peer: " & e.msg)
  else:
    return err("Peer debug API is disabled")

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
  of NodeDebugMsgType.PEER:
    let res = (await getPeer(codex, self.peerId))
    if res.isErr:
      error "PEER failed", error = res.error
      return err($res.error)
    return res

  return ok("")
