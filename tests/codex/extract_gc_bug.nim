import std/[isolation, macros, sequtils,tasks]
import std/importutils
import system/ansi_c

privateAccess Task

const size = 10000

proc someTask(input: seq[seq[int]]) =
  var sum = 0.int

  for i in 0..<len(input):
    for j in 0..<len(input[i]):
      sum = sum + input[i][j]

  echo $sum

proc main() =
  # 100 numbers of value 1
  let input = newSeqWith[seq[int]](size, newSeqWith[int](size, 1.int))

  # expandMacros: # expanded version of is in `expandedMain`
  let task = toTask(someTask(input))

  echo "sum is:"
  task.invoke()

  echo "sum should be:"
  someTask(input)

proc expandedMain() =
  # 100 numbers of value 1
  let input = newSeqWith[seq[int]](size, newSeqWith[int](size, 1.int))

  type
    ScratchObj_838860902 = object
      input: seq[seq[int]]

  let scratch_838860896 = cast[ptr ScratchObj_838860902](c_calloc(csize_t(1),
      csize_t(8)))
  if isNil(scratch_838860896):
    raise
      (ref OutOfMemDefect)(msg: "Could not allocate memory", parent: nil)
  
  var isoTemp_838860900 = isolate(input)
  scratch_838860896.input = extract(isoTemp_838860900)

  # discard GC_getStatistics() # GC stats - shouldn't change anything

  GC_fullCollect() # GC - shouldn't change anything
  discard newSeqWith[seq[int]](size, newSeqWith[int](size, 2.int)) # Allocation - shouldn't change anything

  proc someTask_838860903(argsgensym8: pointer) {.gcsafe, nimcall.} =
    let objTemp_838860899 = cast[ptr ScratchObj_838860902](argsgensym8)
    let input_838860901 = objTemp_838860899.input
    someTask(input_838860901)

  proc destroyScratch_838860904(argsgensym8: pointer) {.gcsafe, nimcall.} =
    let obj_838860905 = cast[ptr ScratchObj_838860902](argsgensym8)
    `=destroy`(obj_838860905[])

  let task = Task(callback: someTask_838860903, args: scratch_838860896,
    destroy: destroyScratch_838860904)
  
  echo "sum is:"
  task.invoke()

  echo "sum should be:"
  someTask(input)

main()
echo "---"
expandedMain()
