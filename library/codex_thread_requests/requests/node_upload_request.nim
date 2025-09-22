## This file contains the lifecycle request type that will be handled.
{.push raises: [].}

import std/[options, os, mimetypes, streams]
import chronos
import chronicles
import libp2p
import ../../alloc
import ../../../codex/streams
import ../../../codex/node

from ../../../codex/codex import CodexServer, node

type NodeUploadMsgType* = enum
  INIT
  CHUNK
  FINALIZE
  CANCEL
  FILE

type OnProgressHandler =
  proc(bytes: int): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

type NodeUploadRequest* = object
  operation: NodeUploadMsgType
  sessionId: cstring
  filepath: cstring
  chunk: seq[byte]
  chunkSize: csize_t
  onProgress: OnProgressHandler

type
  UploadSessionId* = string
  UploadSessionCount* = int
  UploadSession* = object
    stream: BufferStream
    fut: Future[?!Cid]
    filepath: string
    chunkSize: int

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nexUploadSessionCount {.threadvar.}: UploadSessionCount

proc createShared*(
    T: type NodeUploadRequest,
    op: NodeUploadMsgType,
    sessionId: cstring = "",
    filepath: cstring = "",
    chunk: seq[byte] = @[],
    onProgress: OnProgressHandler = nil,
    chunkSize: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].sessionId = sessionId.alloc()
  ret[].filepath = filepath.alloc()
  ret[].chunk = chunk
  ret[].chunkSize = chunkSize
  ret[].onProgress = onProgress
  return ret

proc destroyShared(self: ptr NodeUploadRequest) =
  deallocShared(self[].filepath)
  deallocShared(self[].sessionId)
  deallocShared(self)

## Init upload create a new upload session and returns its ID.
## The session can be used to send chunks of data
## and to pause and resume the upload.
## filepath can be the absolute path to a file to upload directly,
## or it can be the filename when the file will be uploaded via chunks.
## The mimetype is deduced from the filename extension.
proc init(
    codex: ptr CodexServer,
    filepath: cstring = "",
    chunkSize: csize_t = 0,
    onProgress: OnProgressHandler,
): Future[Result[string, string]] {.async: (raises: []).} =
  var filenameOpt, mimetypeOpt = string.none

  if isAbsolute($filepath):
    if not fileExists($filepath):
      return err("File does not exist")

  if filepath != "":
    let (_, name, ext) = splitFile($filepath)

    filenameOpt = (name & ext).some

    if ext != "":
      let extNoDot =
        if ext.len > 0:
          ext[1 ..^ 1]
        else:
          ""
      let mime = newMimetypes()
      let mimetypeStr = mime.getMimetype(extNoDot, "")

      mimetypeOpt = if mimetypeStr == "": string.none else: mimetypeStr.some

  let sessionId = $nexUploadSessionCount
  nexUploadSessionCount.inc()

  let stream = BufferStream.new()
  let lpStream = LPStream(stream)
  let node = codex[].node

  let onBlockStore = proc(
      chunk: seq[byte]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    discard onProgress(chunk.len)

  let blockSize =
    if chunkSize.NBytes > 0.NBytes: chunkSize.NBytes else: DefaultBlockSize
  let fut = node.store(lpStream, filenameOpt, mimetypeOpt, blockSize, onBlockStore)

  proc cb(_: pointer) {.raises: [].} =
    # Signal end of upload
    discard onProgress(-1)

  fut.addCallback(cb)

  uploadSessions[sessionId] = UploadSession(
    stream: stream, fut: fut, filepath: $filepath, chunkSize: blockSize.int
  )

  return ok(sessionId)

proc chunk(
    codex: ptr CodexServer, sessionId: cstring, chunk: seq[byte]
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  try:
    let session = uploadSessions[$sessionId]
    await session.stream.pushData(chunk)
  except KeyError as e:
    return err("Invalid session ID")
  except LPError as e:
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")

  return ok("")

proc finalize(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  var session: UploadSession
  try:
    session = uploadSessions[$sessionId]
    await session.stream.pushEof()
  except KeyError as e:
    return err("Invalid session ID")
  except LPStreamError as e:
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")

  try:
    let res = await session.fut
    if res.isErr:
      return err("Upload failed: " & res.error().msg)

    return ok($res.get())
  except CatchableError as e:
    return err("Upload failed: " & $e.msg)
  finally:
    uploadSessions.del($sessionId)

proc cancel(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  try:
    let session = uploadSessions[$sessionId]
    session.fut.cancel()
  except KeyError as e:
    return err("Invalid session ID")

  uploadSessions.del($sessionId)

  return ok("")

proc file(
    codex: ptr CodexServer, sessionId: cstring
): Future[Result[string, string]] {.raises: [], async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Invalid session ID")

  var session: UploadSession

  ## Here we certainly need to spawn a new thread to avoid blocking
  ## the worker thread while reading the file.
  try:
    session = uploadSessions[$sessionId]
    var buffer = newSeq[byte](session.chunkSize)
    let fs = openFileStream(session.filepath)
    defer:
      fs.close()

    while true:
      let bytesRead = fs.readData(addr buffer[0], buffer.len)

      if bytesRead == 0:
        break
      await session.stream.pushData(buffer[0 ..< bytesRead])

    return await codex.finalize(sessionId)
  except KeyError as e:
    return err("Invalid session ID")
  except LPStreamError, IOError:
    let e = getCurrentException()
    return err("Stream error: " & $e.msg)
  except CancelledError as e:
    return err("Operation cancelled")
  except CatchableError as e:
    return err("Upload failed: " & $e.msg)
  finally:
    session.fut.cancel()
    uploadSessions.del($sessionId)

proc process*(
    self: ptr NodeUploadRequest, codex: ptr CodexServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeUploadMsgType.INIT:
    let res = (await init(codex, self.filepath, self.chunkSize, self.onProgress))
    if res.isErr:
      error "INIT failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CHUNK:
    let res = (await chunk(codex, self.sessionId, self.chunk))
    if res.isErr:
      error "CHUNK failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FINALIZE:
    let res = (await finalize(codex, self.sessionId))
    if res.isErr:
      error "FINALIZE failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CANCEL:
    let res = (await cancel(codex, self.sessionId))
    if res.isErr:
      error "CANCEL failed", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FILE:
    let res = (await file(codex, self.sessionId))
    if res.isErr:
      error "FILE failed", error = res.error
      return err($res.error)
    return res

  return ok("")
