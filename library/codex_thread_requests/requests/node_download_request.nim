{.push raises: [].}

## This file contains the download request.
## A session is created for each download identified by the CID,
## allowing to resume, pause and cancel the download (using chunks).
##
## There are two ways to download a file:
## 1. Via chunks: the cid parameter is the CID of the file to download. Steps are:
##    - INIT: initializes the download session
##    - CHUNK: downloads the next chunk of the file
##    - CANCEL: cancels the download session
## 2. Via stream.
##    - STREAM: downloads the file in a streaming manner, calling
## the onChunk handler for each chunk and / or writing to a file if filepath is set.
## Cancel is supported in this mode because the worker will be busy
## downloading the file so it cannot pickup another request to cancel the download.

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
  CHUNK
  STREAM
  CANCEL

type OnChunkHandler = proc(bytes: seq[byte]): void {.gcsafe, raises: [].}

type NodeDownloadRequest* = object
  operation: NodeDownloadMsgType
  cid: cstring
  chunkSize: csize_t
  local: bool
  filepath: cstring

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
    filepath: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()
  ret[].chunkSize = chunkSize
  ret[].local = local
  ret[].filepath = filepath.alloc()

  return ret

proc destroyShared(self: ptr NodeDownloadRequest) =
  deallocShared(self)

proc init(
    codex: ptr CodexServer, cCid: cstring = "", chunkSize: csize_t = 0, local: bool
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

proc streamData(
    codex: ptr CodexServer,
    cid: Cid,
    local: bool,
    onChunk: OnChunkHandler,
    chunkSize: csize_t,
    filepath: cstring,
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
  var outputStream: OutputStreamHandle
  var filedest: string = $filepath

  try:
    if filepath != "":
      outputStream = filedest.fileOutput()

    while not stream.atEof:
      let read = await stream.readOnce(addr buf[0], buf.len)
      buf.setLen(read)

      if buf.len <= 0:
        break

      onChunk(buf)

      if outputStream != nil:
        outputStream.write(buf)

    if outputStream != nil:
      outputStream.close()
  except LPStreamError as e:
    return err("Failed to stream file: " & $e.msg)
  except IOError as e:
    return err("Failed to write to file: " & $e.msg)
  finally:
    await stream.close()
    downloadSessions.del($cid)

  return ok("")

proc stream(
    codex: ptr CodexServer,
    cCid: cstring,
    chunkSize: csize_t,
    local: bool,
    filepath: cstring,
    onChunk: OnChunkHandler,
): Future[Result[string, string]] {.raises: [], async: (raises: []).} =
  let node = codex[].node

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to download locally: cannot parse cid: " & $cCid)

  try:
    let res = await codex.streamData(cid.get(), local, onChunk, chunkSize, filepath)
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
  of NodeDownloadMsgType.CHUNK:
    let res = (await chunk(codex, self.cid, onChunk))
    if res.isErr:
      error "Failed to CHUNK.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.STREAM:
    let res = (
      await stream(codex, self.cid, self.chunkSize, self.local, self.filepath, onChunk)
    )
    if res.isErr:
      error "Failed to STREAM.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.CANCEL:
    let res = (await cancel(codex, self.cid))
    if res.isErr:
      error "Failed to CANCEL.", error = res.error
      return err($res.error)
    return res
