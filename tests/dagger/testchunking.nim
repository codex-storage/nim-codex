import pkg/asynctest
import pkg/stew/byteutils
import pkg/dagger/chunker
import pkg/chronicles
import pkg/chronos
import pkg/libp2p

suite "Chunking":
  test "should return proper size chunks":
    var offset = 0
    let contents = [1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    proc reader(data: ChunkBuffer, len: int): Future[int]
      {.gcsafe, async, raises: [Defect].} =
      if offset >= contents.len:
        return 0

      copyMem(data, unsafeAddr contents[offset], len)
      offset += 2
      return len

    let chunker = Chunker.new(
      reader = reader,
      chunkSize = 2)

    check:
      (await chunker.getBytes()) == [1.byte, 2]
      (await chunker.getBytes()) == [3.byte, 4]
      (await chunker.getBytes()) == [5.byte, 6]
      (await chunker.getBytes()) == [7.byte, 8]
      (await chunker.getBytes()) == [9.byte, 0]
      (await chunker.getBytes()) == []

  test "should chunk LPStream":
    var offset = 0
    let stream = BufferStream.new()
    let chunker = LPStreamChunker.new(
      stream = stream,
      chunkSize = 2)

    proc writer() {.async.} =
      for d in [@[1.byte, 2, 3, 4], @[5.byte, 6, 7, 8], @[9.byte, 0]]:
        await stream.pushData(d)
      await stream.pushEof()
      await stream.close()

    let writerFut = writer()
    check:
      (await chunker.getBytes()) == [1.byte, 2]
      (await chunker.getBytes()) == [3.byte, 4]
      (await chunker.getBytes()) == [5.byte, 6]
      (await chunker.getBytes()) == [7.byte, 8]
      (await chunker.getBytes()) == [9.byte, 0]
      (await chunker.getBytes()) == []

    await writerFut

  test "should chunk file":
    let
      (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name
      file = open(path)
      fileChunker = FileChunker.new(file = file, chunkSize = 256, pad = false)

    var data: seq[byte]
    while true:
      let buff = await fileChunker.getBytes()
      if buff.len <= 0:
        break

      check buff.len <= fileChunker.chunkSize
      data.add(buff)

    check string.fromBytes(data) == readFile(path)
