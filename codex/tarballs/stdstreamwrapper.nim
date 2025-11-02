## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/streams
import pkg/libp2p
import pkg/chronos

import ../logutils

logScope:
  topics = "libp2p stdstreamwrapper"

const StdStreamWrapperName* = "StdStreamWrapper"

type StdStreamWrapper* = ref object of LPStream
  stream*: Stream

method initStream*(self: StdStreamWrapper) =
  if self.objName.len == 0:
    self.objName = StdStreamWrapperName

  procCall LPStream(self).initStream()

proc newStdStreamWrapper*(stream: Stream = nil): StdStreamWrapper =
  let stream = StdStreamWrapper(stream: stream)

  stream.initStream()
  return stream

template withExceptions(body: untyped) =
  try:
    body
  except CatchableError as exc:
    raise newException(Defect, "Unexpected error in StdStreamWrapper", exc)

method readOnce*(
    self: StdStreamWrapper, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Reading bytes from stream", bytes = nbytes
  if isNil(self.stream):
    error "StdStreamWrapper: stream is nil"
    raiseAssert("StdStreamWrapper: stream is nil")

  if self.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    return self.stream.readData(pbytes, nbytes)

method atEof*(self: StdStreamWrapper): bool =
  withExceptions:
    return self.stream.atEnd()

method closeImpl*(self: StdStreamWrapper) {.async: (raises: []).} =
  try:
    trace "Shutting down std stream"

    self.stream.close()

    trace "Shutdown async chronos stream"
  except CatchableError as exc:
    trace "Error closing std stream", msg = exc.msg

  await procCall LPStream(self).closeImpl()
