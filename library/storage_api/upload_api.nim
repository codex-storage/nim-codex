## Upload sessions: chunks (init, chunk*, finalize) or a local path (init, file).

import std/[options, os, mimetypes, tables]
import chronos
import chronicles
import questionable
import questionable/results
import results
import ffi
import faststreams/inputs
import libp2p/stream/[bufferstream, lpstream]
import ../declare_lib
import ../events
import ../../storage/units
import ../../storage/storagetypes

from ../../storage/storage import StorageServer, node
from ../../storage/node import store
from libp2p import Cid, `$`

logScope:
  topics = "libstorage upload"

type OnProgressHandler = proc(bytes: int): void {.gcsafe, raises: [].}

type
  UploadSessionId = string
  UploadSession = object
    stream: BufferStream
    fut: Future[?!Cid]
    filepath: string
    chunkSize: int
    onProgress: OnProgressHandler

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nextUploadSessionCount {.threadvar.}: int

proc resetUploadSessions*() =
  ## The ctor calls this: nim-ffi hands a recycled FFI thread to the next context.
  uploadSessions.clear()
  nextUploadSessionCount = 0

proc describeUpload(filepath: string): (Option[string], Option[string]) =
  ## Derives the stored filename and mime type from the upload path.
  if filepath == "":
    return (string.none, string.none)

  let (_, name, ext) = splitFile(filepath)
  if ext == "":
    return ((name & ext).some, string.none)

  let mimetypeStr = newMimetypes().getMimetype(ext[1 ..^ 1], "")
  let mimetype = if mimetypeStr == "": string.none else: mimetypeStr.some

  return ((name & ext).some, mimetype)

proc storage_upload_init(
    self: Storage, filepath: string, chunkSize: uint64
): Future[Result[string, string]] {.ffi.} =
  ## Opens a session. `filepath` is an absolute path, or a name for a chunked upload.
  if isAbsolute(filepath) and not fileExists(filepath):
    return err(
      "Failed to create an upload session, the filepath does not exist: " & filepath
    )

  let (filenameOpt, mimetypeOpt) = describeUpload(filepath)
  let sessionId = $nextUploadSessionCount
  nextUploadSessionCount.inc()

  let stream = BufferStream.new()

  let onBlockStored = proc(chunk: seq[byte]): void {.gcsafe, raises: [].} =
    try:
      if uploadSessions.contains(sessionId):
        let session = uploadSessions[sessionId]
        if session.onProgress != nil:
          session.onProgress(chunk.len)
    except KeyError:
      error "Failed to push progress update, session is not found: ",
        sessionId = sessionId

  let blockSize =
    if chunkSize.NBytes > 0.NBytes: chunkSize.NBytes else: DefaultBlockSize
  let fut = self.node.store(
    LPStream(stream), filenameOpt, mimetypeOpt, blockSize, onBlockStored
  )

  uploadSessions[sessionId] = UploadSession(
    stream: stream, fut: fut, filepath: filepath, chunkSize: blockSize.int
  )

  return ok(sessionId)

proc storage_upload_chunk(
    self: Storage, sessionId: string, data: seq[byte]
): Future[Result[string, string]] {.ffi.} =
  ## Pushes one chunk into the session's stream and returns once it is consumed.
  # A chunk that fills a block waits on onBlockStored; a smaller one waits on pushData.
  if not uploadSessions.contains(sessionId):
    return err("Failed to upload the chunk, the session is not found: " & sessionId)

  var fut = newFuture[void]()

  try:
    let session = uploadSessions[sessionId]

    if data.len >= session.chunkSize:
      uploadSessions[sessionId].onProgress = proc(
          bytes: int
      ): void {.gcsafe, raises: [].} =
        fut.complete()
      await session.stream.pushData(data)
    else:
      fut = session.stream.pushData(data)

    await fut

    uploadSessions[sessionId].onProgress = nil
  except KeyError:
    return err("Failed to upload the chunk, the session is not found: " & sessionId)
  except LPError as e:
    return err("Failed to upload the chunk, stream error: " & e.msg)
  except CancelledError:
    return err("Failed to upload the chunk, operation cancelled.")
  except CatchableError as e:
    return err("Failed to upload the chunk: " & e.msg)
  finally:
    fut.cancelSoon()

  return ok("")

proc finalizeUpload(
    sessionId: string
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains(sessionId):
    return err("Failed to finalize the upload session, session not found: " & sessionId)

  var session: UploadSession
  try:
    session = uploadSessions[sessionId]
    await session.stream.pushEof()

    let res = await session.fut
    if res.isErr:
      return err("Failed to finalize the upload session: " & res.error().msg)

    return ok($res.get())
  except KeyError:
    return
      err("Failed to finalize the upload session, invalid session ID: " & sessionId)
  except LPStreamError as e:
    return err("Failed to finalize the upload session, stream error: " & e.msg)
  except CancelledError:
    return err("Failed to finalize the upload session, operation cancelled")
  except CatchableError as e:
    return err("Failed to finalize the upload session: " & e.msg)
  finally:
    uploadSessions.del(sessionId)

    if session.fut != nil:
      session.fut.cancelSoon()

proc storage_upload_finalize(
    self: Storage, sessionId: string
): Future[Result[string, string]] {.ffi.} =
  ## Closes the session's stream and returns the CID of the stored content.
  return await finalizeUpload(sessionId)

proc storage_upload_cancel(
    self: Storage, sessionId: string
): Future[Result[string, string]] {.ffi.} =
  ## Cancels the session. Cancelling an unknown session succeeds.
  if not uploadSessions.contains(sessionId):
    return ok("")

  try:
    uploadSessions[sessionId].fut.cancelSoon()
  except KeyError:
    return ok("")

  uploadSessions.del(sessionId)

  return ok("")

proc streamFile(
    filepath: string, stream: BufferStream, chunkSize: int
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Nested `waitFor` rules out `fsMultiSync`: https://github.com/status-im/nim-chronos/issues/501
  try:
    let inputStreamHandle = filepath.fileInput()
    let inputStream = inputStreamHandle.implicitDeref

    var buf = newSeq[byte](chunkSize)
    while inputStream.readable:
      let read = inputStream.readIntoEx(buf)
      if read == 0:
        break
      await stream.pushData(buf[0 ..< read])

    return ok()
  except IOError, OSError, LPStreamError:
    let e = getCurrentException()
    return err("Failed to stream the file: " & e.msg)

proc storage_upload_file(
    self: Storage, sessionId: string
): Future[Result[string, string]] {.ffi.} =
  ## Uploads the file named at init and returns the CID, firing `on_upload_progress`.
  if not uploadSessions.contains(sessionId):
    return err("Failed to upload the file, invalid session ID: " & sessionId)

  var session: UploadSession

  try:
    uploadSessions[sessionId].onProgress = proc(
        bytes: int
    ): void {.gcsafe, raises: [].} =
      onUploadProgress(sessionId, bytes)
    session = uploadSessions[sessionId]

    let res = await streamFile(session.filepath, session.stream, session.chunkSize)
    if res.isErr:
      return err("Failed to upload the file: " & res.error)

    return await finalizeUpload(sessionId)
  except KeyError:
    return err("Failed to upload the file, the session is not found: " & sessionId)
  except CancelledError:
    return err("Failed to upload the file, the operation is cancelled.")
  except CatchableError as e:
    return err("Failed to upload the file: " & e.msg)
  finally:
    uploadSessions.del(sessionId)

    if session.fut != nil:
      session.fut.cancelSoon()
