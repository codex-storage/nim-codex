import std/unittest
import pkg/stew/byteutils
import pkg/dagger/chunker

suite "Chunking":
  test "should return proper size chunks":
    proc reader(data: var openArray[byte], offset: Natural = 0): int
      {.gcsafe, closure, raises: [Defect].} =
      let contents = "1234567890".toBytes
      copyMem(addr data[0], unsafeAddr contents[offset], data.len)
      return data.len

    let chunker = Chunker.new(
      reader = reader,
      size = 10,
      chunkSize = 2)

    check chunker.getBytes() == "12".toBytes
    check chunker.getBytes() == "34".toBytes
    check chunker.getBytes() == "56".toBytes
    check chunker.getBytes() == "78".toBytes
    check chunker.getBytes() == "90".toBytes
    check chunker.getBytes() == "".toBytes

  test "should chunk file":
    let (fileName, _, _) = instantiationInfo() # get this file's name
    let path = "tests/dagger/" & filename
    let file = open(path)
    let fileChunker = newFileChunker(file = file)

    var data: seq[byte]
    while true:
      let buff = fileChunker.getBytes()
      if buff.len <= 0:
        break

      check buff.len <= fileChunker.chunkSize
      data.add(buff)

    check string.fromBytes(data) == readFile(path)
