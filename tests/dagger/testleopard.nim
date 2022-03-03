# import std/os
# import std/random
import std/sequtils
import std/strformat

import pkg/dagger/leopard
import pkg/stew/byteutils

type
  TestParameters = object
    original_count: cuint
    recovery_count: cuint
    buffer_bytes  : cuint
    loss_count    : cuint
    seed          : cuint

  Vec = seq[pointer]

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

proc new(T: type Vec, input: seq[seq[byte]]): T =
  input.mapIt(cast[pointer](unsafeAddr it[0]))

proc benchmark(params: TestParameters) =
  var
    # original_data = newSeqWith(params.original_count.int,
    #   newSeq[byte](params.buffer_bytes))

    # original_data_0 = newSeqWith(params.original_count.int, hello.toBytes)
    # original_data = Vec.new(original_data_0)

    hello01 = "hello world01                                                   "
    hello02 = "hello world02                                                   "
    hello03 = "hello world03                                                   "
    hello04 = "hello world04                                                   "
    hello05 = "hello world05                                                   "
    hello06 = "hello world06                                                   "
    hello07 = "hello world07                                                   "
    hello08 = "hello world08                                                   "
    hello09 = "hello world09                                                   "
    hello10 = "hello world10                                                   "
    hello11 = "hello world11                                                   "
    hello12 = "hello world12                                                   "
    hello13 = "hello world13                                                   "
    hello14 = "hello world14                                                   "
    hello15 = "hello world15                                                   "
    hello16 = "hello world16                                                   "
    hello17 = "hello world17                                                   "
    hello18 = "hello world18                                                   "
    hello19 = "hello world19                                                   "
    hello20 = "hello world20                                                   "

    original_data_0 = @[
      hello01.toBytes,
      hello02.toBytes,
      hello03.toBytes,
      hello04.toBytes,
      hello05.toBytes,
      hello06.toBytes,
      hello07.toBytes,
      hello08.toBytes,
      hello09.toBytes,
      hello10.toBytes,
      hello11.toBytes,
      hello12.toBytes,
      hello13.toBytes,
      hello14.toBytes,
      hello15.toBytes,
      hello16.toBytes,
      hello17.toBytes,
      hello18.toBytes,
      hello19.toBytes,
      hello20.toBytes
    ]

    original_data = Vec.new(original_data_0)

  # debugEcho $original_data_0.mapIt(repr it)
  # debugEcho $original_data.mapIt(repr cast[seq[byte]](cast[pointer](cast[int](it) - 16)))
  debugEcho $original_data.mapIt(cast[int](it))

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
    encode_work_data_0 = newSeqWith(encode_work_count.int,
      newSeq[byte](params.buffer_bytes))

    encode_work_data = Vec.new(encode_work_data_0)

    decode_work_data_0 = newSeqWith(decode_work_count.int,
      newSeq[byte](params.buffer_bytes))

    decode_work_data = Vec.new(decode_work_data_0)

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

  original_data[0]  = nil
  original_data[17] = nil

  encode_work_data[0] = nil
  encode_work_data[1] = nil
  # encode_work_data[2] = nil
  encode_work_data[3] = nil
  encode_work_data[4] = nil
  encode_work_data[5] = nil
  encode_work_data[6] = nil
  encode_work_data[7] = nil
  encode_work_data[8] = nil
  # encode_work_data[9] = nil

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

  debugEcho $original_data.mapIt((if it.isNil: @[] else: cast[seq[byte]](cast[pointer](cast[int](it) - 16))).len)
  debugEcho $encode_work_data.mapIt((if it.isNil: @[] else: cast[seq[byte]](cast[pointer](cast[int](it) - 16))).len)
  debugEcho $decode_work_data.mapIt(cast[seq[byte]](cast[pointer](cast[int](it) - 16)).len)
  # debugEcho $decode_work_data.mapIt(cast[seq[byte]](cast[pointer](cast[int](it) - 16)))

proc main() =
  if leo_init() != 0: raise (ref Defect)(msg: "Leopard failed to initialize")

  var params = TestParameters.init(buffer_bytes = 64, original_count = 20)

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
