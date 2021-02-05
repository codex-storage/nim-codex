import std/unittest
import std/os
import pkg/ipfs/chunking

suite "chunking":

  var input, output: File

  setup:
    input = open("tests/input.txt", fmReadWrite)
    output = open("tests/output.txt", fmReadWrite)
    input.write("foo")
    input.setFilePos(0)

  teardown:
    input.close()
    output.close()
    removeFile("tests/input.txt")
    removeFile("tests/output.txt")

  test "creates an IPFS object from a file":
    check createObject(input) != IpfsObject.default

  test "writes an IPFS object to a file":
    let obj = createObject(input)
    writeToFile(obj, output)

    input.setFilePos(0)
    output.setFilePos(0)
    check output.readAll() == input.readAll()

