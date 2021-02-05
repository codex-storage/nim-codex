import std/os
import pkg/asynctest
import pkg/chronos
import pkg/ipfs

suite "integration":

  let address = MultiAddress.init("/ip4/127.0.0.1/tcp/48952").get()

  var peer1, peer2: Ipfs
  var input, output: File

  proc setupPeers {.async.} =
    peer1 = await Ipfs.start(address)
    peer2 = await Ipfs.start()
    await peer2.connect(peer1.info)

  proc setupFiles =
    input = open("tests/input.txt", fmReadWrite)
    output = open("tests/output.txt", fmReadWrite)
    input.write("foo")
    input.setFilePos(0)

  proc teardownPeers {.async.} =
    await peer1.stop()
    await peer2.stop()

  proc teardownFiles =
    input.close()
    output.close()
    removeFile("tests/input.txt")
    removeFile("tests/output.txt")

  setup:
    await setupPeers()
    setupFiles()

  teardown:
    await teardownPeers()
    teardownFiles()

  test "file can be transferred from one peer to another":
    let identifier = await peer1.add(input)
    await peer2.get(identifier, output)

    input.setFilePos(0)
    output.setFilePos(0)
    check output.readAll() == input.readAll()
