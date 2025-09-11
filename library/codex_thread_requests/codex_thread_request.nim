## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Codex Thread.

import std/json
import results
import chronos
import ../ffi_types
import ./requests/node_lifecycle_request

from ../../codex/codex import CodexServer

type RequestType* {.pure.} = enum
  LIFECYCLE

type CodexThreadRequest* = object
  reqType: RequestType

  # Request payloed
  reqContent: pointer

  # Callback to notify the client thread of the result
  callback: CodexCallback

  # Custom state attached by the client to the request,
  # returned when its callback is invoked.
  userData: pointer

proc createShared*(
    T: type CodexThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: CodexCallback,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

# NOTE: User callbacks are executed on the working thread.
# They must be fast and non-blocking; otherwise this thread will be blocked
# and no further requests can be processed.
# We can improve this by dispatching the callbacks to a thread pool or
# moving to a MP channel.
# See: https://github.com/codex-storage/nim-codex/pull/1322#discussion_r2340708316
proc handleRes[T: string | void](
    res: Result[T, string], request: ptr CodexThreadRequest
) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].
  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = "libcodex error: handleRes fireSyncRes error: " & $res.error
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
      )
    return

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    request[].callback(
      RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

proc process*(
    T: type CodexThreadRequest, request: ptr CodexThreadRequest, codex: ptr CodexServer
) {.async: (raises: []).} =
  ## Processes the request in the Codex thread.
  ## Dispatch to the appropriate request handler based on reqType.
  let retFut =
    case request[].reqType
    of LIFECYCLE:
      cast[ptr NodeLifecycleRequest](request[].reqContent).process(codex)

  handleRes(await retFut, request)

proc `$`*(self: CodexThreadRequest): string =
  return $self.reqType
