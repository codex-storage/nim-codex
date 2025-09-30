{.push raises: [].}

## This file contains the download request.

import std/[options, streams]
import chronos
import chronicles
import libp2p/stream/[lpstream]
import ../../alloc
import ../../../codex/units
import ../../../codex/codextypes

from ../../../codex/codex import CodexServer, node
from ../../../codex/node import retrieve
from libp2p import Cid, init, `$`

logScope:
  topics = "codexlib codexlibdownload"

type NodeDownloadMsgType* = enum
  INIT
  LOCAL
  NETWORK
  CHUNK
  CANCEL

type OnChunkHandler = proc(bytes: seq[byte]): void {.gcsafe, raises: [].}

type NodeDownloadRequest* = object
  operation: NodeDownloadMsgType
  cid: cstring
  chunkSize: csize_t
  local: bool

type
  DownloadSessionId* = string
  DownloadSessionCount* = int
  DownloadSession* = object
    stream: LPStream
    chunkSize: int

var downloadSessions {.threadvar.}: Table[DownloadSessionId, DownloadSession]

proc createShared*(
    T: type NodeDownloadRequest,
    op: NodeDownloadMsgType,
    cid: cstring = "",
    chunkSize: csize_t = 0,
    local: bool = false,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()
  ret[].chunkSize = chunkSize
  ret[].local = local

  return ret

proc destroyShared(self: ptr NodeDownloadRequest) =
  deallocShared(self)

proc init(
    codex: ptr CodexServer,
    cCid: cstring = "",
    chunkSize: csize_t = 0,
    local: bool = true,
): Future[Result[string, string]] {.async: (raises: []).} =
  if downloadSessions.contains($cCid):
    return ok("Download session already exists.")

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to download locally: cannot parse cid: " & $cCid)

  let node = codex[].node
  var stream: LPStream

  try:
    let res = await node.retrieve(cid.get(), local)
    if res.isErr():
      return err("Failed to init the download: " & res.error.msg)
    stream = res.get()
  except CancelledError:
    downloadSessions.del($cCid)
    return err("Failed to init the download: download cancelled.")

  let blockSize = if chunkSize.int > 0: chunkSize.int else: DefaultBlockSize.int
  downloadSessions[$cCid] = DownloadSession(stream: stream, chunkSize: blockSize)

  return ok("")

proc chunk(
    codex: ptr CodexServer, cid: cstring = "", onChunk: OnChunkHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  if not downloadSessions.contains($cid):
    return err("Failed to download chunk: no session for cid " & $cid)

  var session: DownloadSession
  try:
    session = downloadSessions[$cid]
  except KeyError:
    return err("Failed to download chunk: no session for cid " & $cid)

  let stream = session.stream
  let chunkSize = session.chunkSize

  if stream.atEof:
    return ok("")

  var buf = newSeq[byte](chunkSize)

  try:
    let read = await stream.readOnce(addr buf[0], buf.len)
    buf.setLen(read)
  except LPStreamError as e:
    await stream.close()
    downloadSessions.del($cid)
    return err("Failed to download chunk: " & $e.msg)
  except CancelledError:
    await stream.close()
    downloadSessions.del($cid)
    return err("Failed to download chunk: download cancelled.")

  if buf.len <= 0:
    return err("Failed to download chunk: no data")

  onChunk(buf)

  return ok("")

proc streamFile(
    codex: ptr CodexServer,
    cid: Cid,
    local: bool = true,
    onChunk: OnChunkHandler,
    chunkSize: csize_t,
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  let node = codex[].node

  let res = await node.retrieve(cid, local = local)
  if res.isErr():
    return err("Failed to retrieve CID: " & res.error.msg)

  let stream = res.get()

  if stream.atEof:
    return err("Failed to retrieve CID: empty stream.")

  let blockSize = if chunkSize.int > 0: chunkSize.int else: DefaultBlockSize.int
  var buf = newSeq[byte](blockSize)

  var read = 0
  try:
    while not stream.atEof:
      let read = await stream.readOnce(addr buf[0], buf.len)
      buf.setLen(read)

      if buf.len <= 0:
        break

      if onChunk != nil:
        onChunk(buf)
  except LPStreamError as e:
    return err("Failed to stream file: " & $e.msg)
  finally:
    await stream.close()
    downloadSessions.del($cid)

  return ok("")

proc local(
    codex: ptr CodexServer, cCid: cstring, chunkSize: csize_t, onChunk: OnChunkHandler
): Future[Result[string, string]] {.raises: [], async: (raises: []).} =
  let node = codex[].node

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to download locally: cannot parse cid: " & $cCid)

  try:
    let local = true
    let res = await codex.streamFile(cid.get(), true, onChunk, chunkSize)
    if res.isErr:
      return err($res.error)
  except CancelledError:
    return err("Failed to download locally: download cancelled.")

  return ok("")

proc cancel(
    codex: ptr CodexServer, cCid: cstring
): Future[Result[string, string]] {.raises: [], async: (raises: []).} =
  if not downloadSessions.contains($cCid):
    return err("Failed to download chunk: no session for cid " & $cCid)

  var session: DownloadSession
  try:
    session = downloadSessions[$cCid]
  except KeyError:
    return err("Failed to download chunk: no session for cid " & $cCid)

  let stream = session.stream
  await stream.close()
  downloadSessions.del($cCid)

  return ok("")

proc process*(
    self: ptr NodeDownloadRequest, codex: ptr CodexServer, onChunk: OnChunkHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeDownloadMsgType.INIT:
    let res = (await init(codex, self.cid, self.chunkSize, self.local))
    if res.isErr:
      error "Failed to INIT.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.LOCAL:
    let res = (await local(codex, self.cid, self.chunkSize, onChunk))
    if res.isErr:
      error "Failed to LOCAL.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.NETWORK:
    return err("NETWORK download not implemented yet.")
    # let res = (await local(codex, self.cid, self.onChunk2, self.chunkSize, onChunk))
    # if res.isErr:
    #   error "Failed to NETWORK.", error = res.error
    #   return err($res.error)
    # return res
  of NodeDownloadMsgType.CHUNK:
    let res = (await chunk(codex, self.cid, onChunk))
    if res.isErr:
      error "Failed to CHUNK.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.CANCEL:
    let res = (await cancel(codex, self.cid))
    if res.isErr:
      error "Failed to CANCEL.", error = res.error
      return err($res.error)
    return res
