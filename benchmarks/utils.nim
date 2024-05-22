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

template benchmark*(benchmarkName: string, count: int, blk: untyped) =
  ## simple benchmarking of a block of code
  var vals = newSeqOfCap[float](nn)
  for i in 1 .. count:
    block:
      let t0 = epochTime()
      `blk`
      let elapsed = epochTime() - t0
      vals.add elapsed

  var elapsedStr = ""
  for v in vals:
    elapsedStr &= ", " & v.formatFloat(format = ffDecimal, precision = 3)
  stdout.styledWriteLine(
    fgGreen, "CPU Time [", benchmarkName, "] ", "avg(", $nn, "): ", elapsedStr, " s"
  )

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
