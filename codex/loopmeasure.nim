import pkg/chronicles

import std/monotimes

type
  LoopMeasure* = ref object of RootObj
    minUs: int64
    maxUs: int64
    avgCount: int64
    avgUs: int64
    current: int64
    isArmed: bool

proc new*(T: type LoopMeasure): LoopMeasure =
  LoopMeasure(
    minUs: 1_000_000_000,
    maxUs: 0,
    avgCount: 0,
    avgUs: 0,
    current: 0,
    isArmed: false
  )

proc loopArm*(loop: LoopMeasure) =
  loop.minUs = 1_000_000_000
  loop.maxUs = 0
  loop.avgCount = 0
  loop.avgUs = 0
  loop.current = 0
  loop.isArmed = true

proc loopDisarm*(loop: LoopMeasure, name: string) =
  loop.isArmed = false
  trace "LoopMeasure", name, min=loop.minUs, max=loop.maxUs, avg=loop.avgUs, count=loop.avgCount

  if loop.avgUs > 100_000:
    error "LoopMeasure: suspiciously high average"

  if loop.maxUs > 250_000:
    error "LoopMeasure upper threshold breached"
    raiseAssert "AAA"

proc startMeasure*(loop: LoopMeasure) =
  loop.current = getMonoTime().ticks

proc stopMeasure*(loop: LoopMeasure) =
  if not loop.isArmed:
    return

  if loop.current == 0:
    return

  let durationNs = (getMonoTime().ticks - loop.current).int64 # < nanoseconds?
  let durationUs = (durationNs div 1_000).int64 # microseconds?

  loop.avgUs = ((loop.avgUs * loop.avgCount) + durationUs) div (loop.avgCount + 1)
  inc loop.avgCount

  if durationUs > loop.maxUs:
    loop.maxUs = durationUs
  if durationUs < loop.minUs:
    loop.minUs = durationUs
