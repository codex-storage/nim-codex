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

template benchmark*(benchmarkName: string, blk: untyped) =
  ## simple benchmarking of a block of code
  let nn = 5
  var vals = newSeqOfCap[float](nn)
  for i in 1 .. nn:
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
