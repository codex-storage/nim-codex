{.push raises: [].}

import std/[times, strformat, random]
import pkg/questionable/results

import pkg/codex/merkletree/poseidon2

import pkg/codex/utils/poseidon2digest
import ../../asynctest

test "Test poseidon2 digestTree":
  randomize(42)
  const
    dataSize = 64 * 1024 # 64KB
    chunkSize = 2 * 1024 # 2KB
    iterations = 10 # Number of iterations

  echo &"Benchmarking digestTree with data size: {dataSize} bytes, chunk size: {chunkSize} bytes"

  # Generate random data
  var data = newSeq[byte](dataSize)
  for i in 0 ..< dataSize:
    data[i] = byte(rand(255))

  # Actual benchmark
  let startTime = cpuTime()

  for i in 1 .. iterations:
    let treeResult = Poseidon2Tree.digestTree(data, chunkSize).tryGet()

    # Optionally print info about each iteration

  let endTime = cpuTime()
  let totalTime = endTime - startTime
  let avgTime = totalTime / iterations.float

  echo &"Results:"
  echo &"  Total time for {iterations} iterations: {totalTime:.6f} seconds"
  echo &"  Average time per iteration: {avgTime:.6f} seconds"
  echo &"  Iterations per second: {iterations.float / totalTime:.2f}"
