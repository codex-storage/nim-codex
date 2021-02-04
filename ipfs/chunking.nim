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
  Reader* = proc(maxSize: int): seq[byte] {.gcsafe, closure.}

  ChunkerType {.pure.} = enum
    SizedChunker
    RabinChunker

  Chunker = object of RootObj
    reader: Reader
    case kind: ChunkerType:
    of SizedChunker:
      size*: int
      pad*: bool # pad last block if less than size
    of RabinChunker:
      min*, max*: int

proc getBytes*(c: Chunker): seq[byte] =
  var bytes = c.reader(c.size)
  if bytes.len < c.size and c.pad:
    bytes.setLen(c.size)

  return bytes

proc newFixedSizeChunker*(
  T: type Chunker,
  reader: Reader,
  size = DefaultBlockSize,
  pad = false): T =
  Chunker(
    kind: ChunkerType.SizedChunker,
    size: size,
    pad: pad)
