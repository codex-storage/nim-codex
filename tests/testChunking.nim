import std/unittest
import std/os
import pkg/dagger/chunking

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

  test "creates a Merkle DAG from a file":
    check createChunks(input) != MerkleDag.default

  test "creates a file from a Merkle DAG":
    let dag = createChunks(input)
    assembleChunks(dag, output)

    input.setFilePos(0)
    output.setFilePos(0)
    check output.readAll() == input.readAll()

