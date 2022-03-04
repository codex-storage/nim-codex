import std/sequtils
import std/strformat
import std/strutils

import pkg/dagger/leopard
import pkg/stew/byteutils

type
  TestParameters = object
    original_count: cuint
    recovery_count: cuint
    buffer_bytes  : cuint

  Vec = seq[pointer]

proc init(
    T: type TestParameters,
    original_count: cuint = 100,
    recovery_count: cuint = 10,
    buffer_bytes  : cuint = 64000): T =
  T(original_count: original_count,
    recovery_count: recovery_count,
    buffer_bytes  : buffer_bytes)

proc new(T: type Vec, input: seq[seq[byte]]): T =
  input.mapIt(cast[pointer](unsafeAddr it[0]))

proc test(params: TestParameters) =
  let
    deadbeef64 = @[
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef,
      0xde, 0xad, 0xbe, 0xef
    ].mapIt(it.byte)

  var
    original_data_0 = newSeqWith(params.original_count.int, deadbeef64)
    original_data = Vec.new(original_data_0)

  debugEcho "\nORIGINAL DATA"
  debugEcho "-------------\n"
  debugEcho $original_data_0.mapIt(it.mapIt(it.toHex(2).toLowerAscii))

  # debugEcho $original_data.mapIt("0x" & (cast[int](it) - 16).toHex(9).toLowerAscii)
  # debugEcho $original_data.mapIt((cast[seq[byte]](cast[pointer](cast[int](it) - 16))).mapIt(it.toHex(2).toLowerAscii))

  let
    encode_work_count = leo_encode_work_count(params.original_count,
      params.recovery_count)
    decode_work_count = leo_decode_work_count(params.original_count,
      params.recovery_count)

  debugEcho "\nencode_work_count: " & $encode_work_count
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

  original_data[53]  = nil
  original_data[199] = nil

  encode_work_data[0]  = nil
  encode_work_data[1]  = nil
  encode_work_data[2]  = nil
  encode_work_data[3]  = nil
  encode_work_data[4]  = nil
  encode_work_data[5]  = nil
  encode_work_data[6]  = nil
  # encode_work_data[7]  = nil
  encode_work_data[8]  = nil
  encode_work_data[9]  = nil
  encode_work_data[10] = nil
  # encode_work_data[11] = nil
  encode_work_data[12] = nil
  encode_work_data[13] = nil
  encode_work_data[14] = nil
  encode_work_data[15] = nil

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

  debugEcho "\nDECODED DATA"
  debugEcho "------------\n"
  debugEcho $decode_work_data.mapIt((cast[seq[byte]](cast[pointer](cast[int](it) - 16))).mapIt(it.toHex(2).toLowerAscii))

proc main() =
  if leo_init() != 0: raise (ref Defect)(msg: "Leopard failed to initialize")

  # https://github.com/catid/leopard/issues/12
  # https://www.cs.cmu.edu/~guyb/realworld/reedsolomon/reed_solomon_codes.html

  # RS(255, 239)
  # ------------
  # original_count = 239
  # recovery_count = 255 - 239 = 16

  var params = TestParameters.init(
    original_count = 239,
    recovery_count = 16,
    buffer_bytes = 64
  )

  debugEcho fmt(
    "Parameters: "                              &
    "[original count={params.original_count}] " &
    "[recovery count={params.recovery_count}] " &
    "[buffer bytes={params.buffer_bytes}] "
  )

  test params

main()
