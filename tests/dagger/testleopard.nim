import std/sequtils
import std/strformat

import pkg/dagger/leopard
import pkg/dagger/rng
import pkg/stew/byteutils
import pkg/stew/ptrops

import pkg/libp2p/varint

const
  LEO_ALIGN_BYTES = 16'u

type
  TestParameters = object
    originalCount: cuint
    recoveryCount: cuint
    bufferBytes  : cuint
    lossCount    : cuint
    seed         : cuint

proc randomCRCPacket(rng: Rng, data: var openArray[byte]) =
  if data.len < 16:
    data[0] = rng.rand(data.len).byte
    for i in 1..<data.len:
      data[i] = data[0]
  else:
    var
      crc = data.len.uint32
      length = data.len.uint
      outlen = 0

    if PB.putUVarint(data.toOpenArray(0, data.len - 1), outlen, length).isOk:
      for i in outlen..<data.len:
        let v = rng.rand(data.len).byte
        data[i] = v
        crc = (crc shl 3) and (crc shr (32 - 3))
        crc += v

    PB.putUVarint(data.toOpenArray(outlen, sizeof(uint32)), outlen, crc).tryGet

proc checkCRCPacket(data: openArray[byte]) =
  if data.len < 16:
    for d in data[1..data.high]:
      if d != data[0]:
        raise (ref Defect)(msg: "Packet don't match")
  else:
    var
      crc = data.len.uint32
      packCrc: uint
      outlen: int
      packSize: uint

    if PB.getVarint(data.toOpenArray(0, data.len - 1), outlen, packSize).isErr:
      raise (ref Defect)(msg: "Unable to read packet size!")

    if packSize != data.len.uint:
      raise (ref Defect)(msg: "Packet size don't match!")

    for i in outlen..<data.len:
      let v = data[i]
      crc = (crc shl 3) and (crc shr (32 - 3))
      crc += v

    if PB.getVarint(data.toOpenArray(outlen, sizeof(uint32)), outlen, packCrc).isErr:
      raise (ref Defect)(msg: "Unable to read packet CRC!")

    if packCrc != crc:
      raise (ref Defect)(msg: "Packet CRC doesn't match!")

proc SIMDSafeAllocate(size: int): pointer {.inline.}  =
  var
    data = alloc0(LEO_ALIGN_BYTES + size.uint)

  if not isNil(data):
    var
      doffset = cast[uint](data) mod LEO_ALIGN_BYTES

    data = offset(data, (LEO_ALIGN_BYTES + doffset).int)
    var
      offsetPtr = cast[pointer](cast[uint](data) - 1'u)
    moveMem(offsetPtr, addr doffset, sizeof(doffset))

    return data

proc SIMDSafeFree(data: pointer) {.inline.} =
  var data = data
  if not isNil(data):
    let offset = cast[uint](data) - 1'u
    if offset >= LEO_ALIGN_BYTES:
        return

    data = cast[pointer](cast[uint](data) - (LEO_ALIGN_BYTES - offset))
    dealloc(data)

proc benchmark(params: TestParameters) =
  let
    rng = Rng.instance()
    encodeWorkCount = leoEncodeWorkCount(
      params.originalCount,
      params.recoveryCount)
    decodeWorkCount = leoDecodeWorkCount(
      params.originalCount,
      params.recoveryCount)

  debugEcho "original work count: " & $params.originalCount
  debugEcho "encode work count: " & $encodeWorkCount
  debugEcho "decode work count: " & $decodeWorkCount

  let
    totalBytes = (params.buffer_bytes * params.originalCount).uint64

  debugEcho "total_bytes: " & $totalBytes

  var
    originalData    = newSeq[pointer](params.originalCount)
    encodeWorkData  = newSeq[pointer](encodeWorkCount)
    decodeWorkData  = newSeq[pointer](decodeWorkCount)

  for i in 0..<params.originalCount:
    originalData[i] = SIMDSafeAllocate(params.bufferBytes.int)
    var
      data = cast[ptr UncheckedArray[byte]](originalData[i])
    rng.randomCRCPacket(data.toOpenArray(0, params.bufferBytes.int - 1))

  for i in 0..<encodeWorkCount.int:
    encodeWorkData[i] = SIMDSafeAllocate(params.bufferBytes.int)

  for i in 0..<decodeWorkCount.int:
    decodeWorkData[i] = SIMDSafeAllocate(params.bufferBytes.int)

  let
    encodeResult = leoEncode(
      params.bufferBytes,
      params.originalCount,
      params.recoveryCount,
      encodeWorkCount,
      addr originalData[0],
      addr encodeWorkData[0]
    )

  debugEcho "encodeResult: " & $leoResultString(encodeResult)

  SIMDSafeFree(originalData[0])
  originalData[0] = nil

  let
    decodeResult = leo_decode(
      params.bufferBytes,
      params.originalCount,
      params.recoveryCount,
      decodeWorkCount,
      addr originalData[0],
      addr encodeWorkData[0],
      addr decodeWorkData[0]
    )

  debugEcho "decodeResult: " & $leo_result_string(decodeResult)
  if originalData[0].isNil:
    var
      data = cast[ptr UncheckedArray[byte]](decodeWorkData[0])

    checkCRCPacket(data.toOpenArray(0, params.bufferBytes.int - 1))
    # debugEcho "Decoded Data: ", cast[ptr char](decodeWorkData[0])

proc init(
  T: type TestParameters,
  originalCount: cuint = 100,
  recoveryCount: cuint = 10,
  bufferBytes  : cuint = 64000,
  lossCount    : cuint = 32768,
  seed         : cuint = 2): T =
  T(originalCount: original_count,
    recoveryCount: recovery_count,
    bufferBytes  : buffer_bytes,
    lossCount    : loss_count,
    seed         : seed)

proc main() =
  if leoInit() != 0: raise (ref Defect)(msg: "Leopard failed to initialize")

  var params = TestParameters.init(buffer_bytes = 64, original_count = 10)

  debugEcho fmt(
    "Parameters: "                              &
    "[original count={params.original_count}] " &
    "[recovery count={params.recovery_count}] " &
    "[buffer bytes={params.buffer_bytes}] "     &
    "[loss count={params.loss_count}] "         &
    "[random seed={params.seed}]"
  )

  benchmark params

main()
