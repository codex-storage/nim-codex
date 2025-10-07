{.push raises: [].}

## This file contains the P2p request type that will be handled.
## CONNECT: connect to a peer with the provided peer ID and optional addresses.

import std/[options]
import chronos
import chronicles
import libp2p
import ../../alloc
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

logScope:
  topics = "codexlib codexlibp2p"

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
    return err("Failed to connect to peer: invalid peer ID: " & $res.error())

  let id = res.get()

  let addresses =
    if peerAddresses.len > 0:
      var addrs: seq[MultiAddress]
      for addrStr in peerAddresses:
        let res = MultiAddress.init($addrStr)
        if res.isOk:
          addrs.add(res[])
        else:
          return err("Failed to connect to peer: invalid address: " & $addrStr)
      addrs
    else:
      try:
        let peerRecord = await node.findPeer(id)
        if peerRecord.isNone:
          return err("Failed to connect to peer: peer not found.")

        peerRecord.get().addresses.mapIt(it.address)
      except CancelledError:
        return err("Failed to connect to peer: operation cancelled.")
      except CatchableError as e:
        return err("Failed to connect to peer: " & $e.msg)

  try:
    await node.connect(id, addresses)
  except CancelledError:
    return err("Failed to connect to peer: operation cancelled.")
  except CatchableError as e:
    return err("Failed to connect to peer: " & $e.msg)

  return ok("")

proc process*(
    self: ptr NodeP2PRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeP2PMsgType.CONNECT:
    let res = (await connect(codex, self.peerId, self.peerAddresses))
    if res.isErr:
      error "Failed to CONNECT.", error = res.error
      return err($res.error)
    return res
