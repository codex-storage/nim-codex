# import std/os
# import std/random
import std/sequtils
import std/strformat

import pkg/dagger/leopard

type
  TestParameters = object
    original_count: cuint
    recovery_count: cuint
    buffer_bytes  : cuint
    loss_count    : cuint
    seed          : cuint

proc init(
    T: type TestParameters,
    original_count: cuint = 100,
    recovery_count: cuint = 10,
    buffer_bytes  : cuint = 64000,
    loss_count    : cuint = 32768,
    seed          : cuint = 2): T =
  T(original_count: original_count,
    recovery_count: recovery_count,
    buffer_bytes  : buffer_bytes,
    loss_count    : loss_count,
    seed          : seed)

proc benchmark(params: TestParameters) =
  var
    original_data = newSeqWith(params.original_count.int,
      newSeq[byte](params.buffer_bytes))

  let
    encode_work_count = leo_encode_work_count(params.original_count,
      params.recovery_count)
    decode_work_count = leo_decode_work_count(params.original_count,
      params.recovery_count)

  debugEcho "encode_work_count: " & $encode_work_count
  debugEcho "decode_work_count: " & $decode_work_count

  let
    total_bytes = (params.buffer_bytes * params.original_count).uint64

  debugEcho "total_bytes: " & $total_bytes

  var
    encode_work_data = newSeqWith(encode_work_count.int,
      newSeq[byte](params.buffer_bytes))
    decode_work_data = newSeqWith(decode_work_count.int,
      newSeq[byte](params.buffer_bytes))

  let
    encodeResult = leo_encode(
      params.buffer_bytes,
      params.original_count,
      params.recovery_count,
      encode_work_count,
      addr original_data[0],
      addr encode_work_data[0]
    )

  debugEcho "encodeResult: " & $leo_result_string(encodeResult)

  let
    decodeResult = leo_decode(
      params.buffer_bytes,
      params.original_count,
      params.recovery_count,
      decode_work_count,
      addr original_data[0],
      addr encode_work_data[0],
      addr decode_work_data[0]
    )

  debugEcho "decodeResult: " & $leo_result_string(decodeResult)

proc main() =
  if leo_init() != 0: raise (ref Defect)(msg: "Leopard failed to initialize")

  var params = TestParameters.init

  debugEcho fmt(
    "Parameters: "                              &
    "[original count={params.original_count}] " &
    "[recovery count={params.recovery_count}] " &
    "[buffer bytes={params.buffer_bytes}] "     &
    "[loss count={params.loss_count}] "         &
    "[random seed={params.seed}]"
  )

  benchmark params

when true: # isMainModule:
  # randomize()
  main()
