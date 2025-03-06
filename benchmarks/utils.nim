import std/tables
import std/times

template withDir*(dir: string, blk: untyped) =
  ## set working dir for duration of blk
  let prev = getCurrentDir()
  try:
    setCurrentDir(dir)
    `blk`
  finally:
    setCurrentDir(prev)

template runit*(cmd: string) =
  ## run shell commands and verify it runs without an error code
  echo "RUNNING: ", cmd
  let cmdRes = execShellCmd(cmd)
  echo "STATUS: ", cmdRes
  assert cmdRes == 0

var benchRuns* = newTable[string, tuple[avgTimeSec: float, count: int]]()

func avg(vals: openArray[float]): float =
  for v in vals:
    result += v / vals.len().toFloat()

template benchmark*(name: untyped, count: int, blk: untyped) =
  let benchmarkName: string = name
  ## simple benchmarking of a block of code
  var runs = newSeqOfCap[float](count)
  for i in 1 .. count:
    block:
      let t0 = epochTime()
      `blk`
      let elapsed = epochTime() - t0
      runs.add elapsed

  var elapsedStr = ""
  for v in runs:
    elapsedStr &= ", " & v.formatFloat(format = ffDecimal, precision = 5)
  stdout.styledWriteLine(
    fgGreen, "CPU Time [", benchmarkName, "] ", "avg(", $count, "): ", elapsedStr, " s"
  )
  benchRuns[benchmarkName] = (runs.avg(), count)

const BenchmarkFile = "benchmarks.csv"

template printBenchMarkSummaries*(
    printRegular = true, printTsv = true, exportExcel = true
) =
  if printRegular:
    echo ""
    for k, v in benchRuns:
      echo "Benchmark average run ", v.avgTimeSec, " for ", v.count, " runs ", "for ", k

  if printTsv:
    echo ""
    echo "name", "\t", "avgTimeSec", "\t", "count"
    for k, v in benchRuns:
      echo k, "\t", v.avgTimeSec, "\t", v.count

  if exportExcel:
    let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
    var f: File
    var isNewFile = not fileExists(BenchmarkFile)

    if f.open(BenchmarkFile, fmAppend):
      try:
        # Write header if new file
        if isNewFile:
          f.writeLine("Timestamp,Benchmark,Average Time (s),Run Count")

        # Write benchmark data
        for name, data in benchRuns:
          f.writeLine(
            [
              timestamp,
              name,
              data.avgTimeSec.formatFloat(format = ffDecimal, precision = 5),
              $data.count,
            ].join(",")
          )

        echo "Benchmark results appended to: ", BenchmarkFile
      finally:
        f.close()
    else:
      echo "Error: Could not open ", BenchmarkFile, " for writing"

import std/math

func floorLog2*(x: int): int =
  var k = -1
  var y = x
  while (y > 0):
    k += 1
    y = y shr 1
  return k

func ceilingLog2*(x: int): int =
  if (x == 0):
    return -1
  else:
    return (floorLog2(x - 1) + 1)

func checkPowerOfTwo*(x: int, what: string): int =
  let k = ceilingLog2(x)
  assert(x == 2 ^ k, ("`" & what & "` is expected to be a power of 2"))
  return x
