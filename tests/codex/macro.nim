let fut = newFlowVar(typeof(DecodeTaskResult))
proc taskpool_decodeTask(args: DecodeTaskArgs; odata: seq[seq[byte]];
                        oparity: seq[seq[byte]]; debug: bool;
                        fut: Flowvar[DecodeTaskResult]) {.nimcall.} =
let res`gensym115 = decodeTask(args, odata, oparity, debug)
readyWith(fut, res`gensym115)

let task =
type
    ScratchObj_11005855178 = object
    args: DecodeTaskArgs
    odata: seq[seq[byte]]
    oparity: seq[seq[byte]]
    debug: bool
    fut: Flowvar[EncodeTaskResult]

let scratch_11005855162 = cast[ptr ScratchObj_11005855178](c_calloc(
    csize_t(1), csize_t(64)))
if isNil(scratch_11005855162):
    raise
    (ref OutOfMemDefect)(msg: "Could not allocate memory", parent: nil)
block:
    var isoTemp_11005855168 = isolate(args)
    scratch_11005855162.args = extract(isoTemp_11005855168)
    var isoTemp_11005855170 = isolate(data[])
    scratch_11005855162.odata = extract(isoTemp_11005855170)
    var isoTemp_11005855172 = isolate(parity[])
    scratch_11005855162.oparity = extract(isoTemp_11005855172)
    var isoTemp_11005855174 = isolate(debug)
    scratch_11005855162.debug = extract(isoTemp_11005855174)
    var isoTemp_11005855176 = isolate(fut)
    scratch_11005855162.fut = extract(isoTemp_11005855176)
proc taskpool_decodeTask_11005855179(args`gensym120: pointer) {.gcsafe,
    nimcall.} =
    let objTemp_11005855167 = cast[ptr ScratchObj_11005855178](args`gensym120)
    let args_11005855169 = objTemp_11005855167.args
    let odata_11005855171 = objTemp_11005855167.odata
    let oparity_11005855173 = objTemp_11005855167.oparity
    let debug_11005855175 = objTemp_11005855167.debug
    let fut_11005855177 = objTemp_11005855167.fut
    taskpool_decodeTask(args_11005855169, odata_11005855171, oparity_11005855173,
                        debug_11005855175, fut_11005855177)

proc destroyScratch_11005855180(args`gensym120: pointer) {.gcsafe, nimcall.} =
    let obj_11005855181 = cast[ptr ScratchObj_11005855178](args`gensym120)
    `=destroy`(obj_11005855181[])

Task(callback: taskpool_decodeTask_11005855179, args: scratch_11005855162,
        destroy: destroyScratch_11005855180)
let taskNode = new(TaskNode, workerContext.currentTask, task)
schedule(workerContext, taskNode)
fut