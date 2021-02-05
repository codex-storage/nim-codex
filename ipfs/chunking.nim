## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ./blocktype

export blocktype

const
  DefaultBlockSize: int64 = 1024 * 256

type
  # default reader type
  Reader* = proc(data: var openarray[byte]): int {.gcsafe, closure.}

  ChunkerType {.pure.} = enum
    SizedChunker
    RabinChunker

  Chunker = object of RootObj
    reader: Reader
    len: Natural
    case kind: ChunkerType:
    of SizedChunker:
      chunkSize*: Natural
      pad*: bool # pad last block if less than size
    of RabinChunker:
      min*, max*: int

proc getBytes*(c: Chunker): seq[byte] =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var bytes = newSeq[byte](c.len)
  var total = 0
  while true:
    let read = c.reader(bytes)
    if read <= 0:
      break

    total += read

  if not c.pad:
    bytes.setLen(total)

  return bytes

iterator iterms*(c: Chunker): seq[byte] =
  while true:
    let bytes = c.getBytes()
    if bytes.len <= 0:
      break

    yield bytes

proc newFileChunker*(
  T: type Chunker,
  file: File,
  kind = ChunkerType.SizedChunker,
  chunkSize = DefaultBlockSize,
  pad = false): T =
  ## create the default File chunker
  ##

  proc reader(data: var openarray[byte]): int =
    return file.readBytes(data, 0, data.len)

  Chunker(
    kind: ChunkerType.SizedChunker,
    reader: reader,
    len: file.getFileSize(),
    pad: pad)

proc new*(
  T: type Chunker,
  kind = ChunkerType.SizedChunker,
  reader: Reader,
  len: Natural,
  chunkSize = DefaultBlockSize,
  pad = false): T =
  Chunker(
    kind: kind,
    reader: reader,
    len: len,
    pad: pad)

when isMainModule:
  var file: File
  if not file.open("./ipfs/repo.nim"):
    echo "cant open"
    quit()

  let chunker = Chunker.newFileChunker(file)
  while true:
    let bytes = chunker.getBytes()
    if bytes.len <= 0:
      break

    echo cast[string](bytes)
