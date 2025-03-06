import std/tables

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

var benchRuns* = newTable[string, tuple[avgTimeSec: float, avgMem: int, count: int]]()

func avg(vals: openArray[float]): float =
  for v in vals:
    result += v / vals.len().toFloat()

template benchmark*(name: untyped, count: int, blk: untyped) =
  let benchmarkName: string = name
  ## simple benchmarking of a block of code
  var times = newSeqOfCap[float](count)
  var mems = newSeqOfCap[int](count)
  for i in 1 .. count:
    block:
      let m0 = getOccupiedMem()
      let t0 = epochTime()
      `blk`
      let elapsed = epochTime() - t0
      let mem = getOccupiedMem() - m0
      times.add elapsed
      mems.add mem

  var elapsedStr = ""
  var memStr = ""
  for v in times:
    elapsedStr &= ", " & v.formatFloat(format = ffDecimal, precision = 3)
  for m in mems:
    memStr &= ", " & $m & " bytes"
  stdout.styledWriteLine(
    fgGreen, "CPU Time [", benchmarkName, "] ", "avg(", $count, "): ", elapsedStr, " s ", memStr
  )
  benchRuns[benchmarkName] = (times.avg(), mems.avg(), count)

template printBenchMarkSummaries*(printRegular=true, printTsv=true) =
  if printRegular:
    echo ""
    for k, v in benchRuns:
      echo "Benchmark average run ", v.avgTimeSec, "s ", v.avgMem, "b for ", v.count, " runs ", "for ", k
    
  if printTsv:
    echo ""
    echo "name", "\t", "avgTimeSec", "\t", "avgMem", "\t", "count"
    for k, v in benchRuns:
      echo k, "\t", v.avgTimeSec, "\t", v.avgMem, "\t", v.count


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
