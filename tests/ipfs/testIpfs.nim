import std/os
import pkg/asynctest
import pkg/chronos
import pkg/ipfs

suite "integration":

  let address = initTAddress("127.0.0.1:48952")

  var peer1, peer2: Ipfs
  var input, output: File

  proc setupPeers =
    peer1 = Ipfs.create()
    peer2 = Ipfs.create()
    peer1.listen(address)
    peer2.connect(address)

  proc setupFiles =
    input = open("tests/input.txt", fmReadWrite)
    output = open("tests/output.txt", fmReadWrite)
    input.write("foo")
    input.setFilePos(0)

  proc teardownPeers =
    peer1.stop()
    peer2.stop()

  proc teardownFiles =
    input.close()
    output.close()
    removeFile("tests/input.txt")
    removeFile("tests/output.txt")

  setup:
    setupPeers()
    setupFiles()

  teardown:
    teardownPeers()
    teardownFiles()

  test "file can be transferred from one peer to another":
    let identifier = await peer1.add(input)
    await peer2.get(identifier, output)

    input.setFilePos(0)
    output.setFilePos(0)
    check output.readAll() == input.readAll()
