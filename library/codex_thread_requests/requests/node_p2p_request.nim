## This file contains the lifecycle request type that will be handled.

import std/[options]
import chronos
import chronicles
import ../../alloc
import libp2p
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

type NodeP2PMsgType* = enum
  CONNECT

type NodeP2PRequest* = object
  operation: NodeP2PMsgType
  peerId: cstring
  peerAddresses: seq[cstring]

proc createShared*(
    T: type NodeP2PRequest,
    op: NodeP2PMsgType,
    peerId: cstring = "",
    peerAddresses: seq[cstring] = @[],
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].peerAddresses = peerAddresses
  return ret

proc destroyShared(self: ptr NodeP2PRequest) =
  deallocShared(self[].peerId)
  deallocShared(self)

proc connect(
    codex: ptr CodexServer, peerId: cstring, peerAddresses: seq[cstring] = @[]
): Future[Result[string, string]] {.async: (raises: []).} =
  let node = codex[].node
  let res = PeerId.init($peerId)
  if res.isErr:
    return err("Invalid peer ID: " & $res.error())

  let id = res.get()

  let addresses =
    if peerAddresses.len > 0:
      var addrs: seq[MultiAddress]
      for addrStr in peerAddresses:
        let res = MultiAddress.init($addrStr)
        if res.isOk:
          addrs.add(res[])
        else:
          return err("Invalid address: " & $addrStr)
      addrs
    else:
      try:
        let peerRecord = await node.findPeer(id)
        if peerRecord.isNone:
          return err("Peer not found")

        peerRecord.get().addresses.mapIt(it.address)
      except CancelledError as e:
        return err("Operation cancelled")
      except CatchableError as e:
        return err("Error finding peer: " & $e.msg)

  try:
    await node.connect(id, addresses)
  except CancelledError as e:
    return err("Operation cancelled")
  except CatchableError as e:
    return err("Connection failed: " & $e.msg)

  return ok("")

proc process*(
    self: ptr NodeP2PRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeP2PMsgType.CONNECT:
    let res = (await connect(codex, self.peerId))
    if res.isErr:
      error "CONNECT failed", error = res.error
      return err($res.error)
    return res

  return ok("")
