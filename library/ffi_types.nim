# FFI Types and Utilities
#
# This file defines the core types and utilities for the library's foreign
# function interface (FFI), enabling interoperability with external code.

################################################################################
### Exported types
import results

type StorageCallback* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_PROGRESS*: cint = 3

## Returns RET_OK as acknowledgment and call the callback
## with RET_OK code and the provided message.
proc success*(callback: StorageCallback, msg: string, userData: pointer): cint =
  callback(RET_OK, cast[ptr cchar](msg), cast[csize_t](len(msg)), userData)

  return RET_OK

## Returns RET_ERR as acknowledgment and call the callback
## with RET_ERR code and the provided message.
proc error*(callback: StorageCallback, msg: string, userData: pointer): cint =
  let msg = "libstorage error: " & msg
  callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)

  return RET_ERR

## Returns RET_OK as acknowledgment if the result is ok.
## If not, return RET_ERR and call the callback with the error message.
proc okOrError*[T](
    callback: StorageCallback, res: Result[T, string], userData: pointer
): cint =
  if res.isOk:
    return RET_OK

  return callback.error($res.error, userData)

### End of exported types
################################################################################

################################################################################
### FFI utils

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

type onDone* = proc()

### End of FFI utils
################################################################################
