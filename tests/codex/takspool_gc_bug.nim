import std/unittest
import std/sugar
import std/sequtils
import std/macros
import std/times
import std/os

import pkg/taskpools
import pkg/taskpools/flowvars

import
  system/ansi_c,
  std/[random, cpuinfo, atomics, macros],
  pkg/taskpools/channels_spsc_single,
  pkg/taskpools/chase_lev_deques,
  pkg/taskpools/event_notifiers,
  pkg/taskpools/primitives/[barriers, allocs],
  pkg/taskpools/instrumentation/[contracts, loggers],
  pkg/taskpools/sparsesets,
  pkg/taskpools/flowvars,
  pkg/taskpools/ast_utils

when (NimMajor,NimMinor,NimPatch) >= (1,6,0):
  import std/[isolation, tasks]
  export isolation
else:
  import pkg/taskpools/shims_pre_1_6/tasks


proc someTask(input: seq[seq[byte]]): byte =
  var sum = 0.byte

  for i in 0..<len(input):
    for j in 0..<len(input[i]):
      sum = sum + input[i][j]

  return sum

proc main() =
  let input = newSeqWith[seq[byte]](10, newSeqWith[byte](10, 1.byte))

  var tp = Taskpool.new(numThreads = 4)

  # ========================== 
  # START OF MACRO EXPANSION
  #
  # expandMacros:
  #   let f1 = tp.spawn someTask(input)

  let fut = newFlowVar(typeof(byte))
  proc taskpool_someTask(input: seq[seq[byte]]; fut: Flowvar[byte]) {.nimcall.} =
    let resgensym25 = someTask(input)
    readyWith(fut, resgensym25)
  type
      ScratchObj_838861353 = object
        input: seq[seq[byte]]
        fut: Flowvar[byte]

  let scratch_838861345 = cast[ptr ScratchObj_838861353](c_calloc(csize_t(1),
      csize_t(16)))
  if isNil(scratch_838861345):
    raise
      (ref OutOfMemDefect)(msg: "Could not allocate memory", parent: nil)


  var isoTemp_838861349 = isolate(input)
  scratch_838861345.input = extract(isoTemp_838861349)

  GC_fullCollect()
  discard newSeqWith[seq[byte]](10, newSeqWith[byte](10, 2.byte)) # Additional allocation - shouldn't change anything (but it will)

  var isoTemp_838861351 = isolate(fut)
  scratch_838861345.fut = extract(isoTemp_838861351)

  proc taskpool_someTask_838861354(argsgensym49: pointer) {.gcsafe, nimcall.} =
    let objTemp_838861348 = cast[ptr ScratchObj_838861353](argsgensym49)
    let input_838861350 = objTemp_838861348.input
    let fut_838861352 = objTemp_838861348.fut
    taskpool_someTask(input_838861350, fut_838861352)

  proc destroyScratch_838861355(argsgensym49: pointer) {.gcsafe, nimcall.} =
    let obj_838861356 = cast[ptr ScratchObj_838861353](argsgensym49)
    `=destroy`(obj_838861356[])

  let task = Task(callback: taskpool_someTask_838861354, args: scratch_838861345,
        destroy: destroyScratch_838861355)
  let taskNode = new(TaskNode, workerContext.currentTask, task)
  schedule(workerContext, taskNode)

  # END OF MACRO EXPANSION
  # ========================== 

  echo "result is " & $(sync(fut)) & " while it should be " & $(someTask(input))
  tp.shutdown()

main()
