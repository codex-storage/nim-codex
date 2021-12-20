import std/sequtils

import pkg/chronos

import pkg/dagger/chunker
import pkg/dagger/rng

export chunker

type
  RandomChunker* = Chunker

proc new*(
  T: type RandomChunker,
  rng: Rng,
  kind = ChunkerType.FixedChunker,
  chunkSize = DefaultChunkSize,
  size: int,
  pad = false): T =
  ## create a chunker that produces
  ## random data
  ##

  var consumed = 0
  proc reader(data: ChunkBuffer, len: int): Future[int]
    {.async, gcsafe, raises: [Defect].} =
    var alpha = toSeq(byte('A')..byte('z'))

    if consumed >= size:
      return 0

    var read = 0
    while read < len:
      rng.shuffle(alpha)
      for a in alpha:
        if read >= len:
          break

        data[read] = a
        read.inc

    consumed += read
    return read

  Chunker.new(
    kind = ChunkerType.FixedChunker,
    reader = reader,
    pad = pad,
    chunkSize = chunkSize)
