import std/sugar

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/stew/endians2
import pkg/stew/byteutils

import ../units

const MaxBufferSize = 10.MiBs.uint

proc encode*(i: uint64): seq[byte] =
  @(i.toBytesBE)

proc decode*(T: type uint64, bytes: seq[byte]): ?!T =
  if bytes.len >= sizeof(uint64):
    success(uint64.fromBytesBE(bytes))
  else:
    failure("Not enough bytes to decode `uint64`")

proc encode*(i: int64): seq[byte] = cast[uint64](i).encode
proc decode*(T: type int64, bytes: seq[byte]): ?!T = uint64.decode(bytes).map((ui: uint64) => cast[int64](ui))

proc encode*(i: int): seq[byte] = cast[uint64](i).encode
proc decode*(T: type int, bytes: seq[byte]): ?!T = uint64.decode(bytes).map((ui: uint64) => cast[int](ui))

proc encode*(i: Natural): seq[byte] = cast[int](i).encode
proc decode*(T: type Natural, bytes: seq[byte]): ?!T = int.decode(bytes).map((ui: int) => cast[Natural](ui))

proc encode*(i: NBytes): seq[byte] = cast[int](i).encode
proc decode*(T: type NBytes, bytes: seq[byte]): ?!T = int.decode(bytes).map((ui: int) => cast[NBytes](ui))

proc encode*[T: enum](e: T): seq[byte] = e.ord().encode
proc decode*(T: typedesc[enum], bytes: seq[byte]): ?!T = int.decode(bytes).map((ui: int) => T(ui))

proc encode*(s: string): seq[byte] = s.toBytes
proc decode*(T: type string, bytes: seq[byte]): ?!T = success(string.fromBytes(bytes))

proc encode*(b: bool): seq[byte] = (if b: @[byte 1] else: @[byte 0])
proc decode*(T: type bool, bytes: seq[byte]): ?!T =
  if bytes.len >= 1:
    success(not (bytes[0] == 0.byte))
  else:
    failure("Not enought bytes to decode `bool`")

proc encode*[T](ts: seq[T]): seq[byte] =
  if ts.len == 0:
    return newSeq[byte]()

  var pb = initProtoBuffer()

  for t in ts:
    pb.write(1, t.encode())

  pb.finish
  pb.buffer


proc decode*[T](_: type seq[T], bytes: seq[byte]): ?!seq[T] =
  if bytes.len == 0:
    return success(newSeq[T]())

  var
    pb = initProtoBuffer(bytes, maxSize = MaxBufferSize)
    nestedBytes: seq[seq[byte]]
    ts: seq[T]

  if ? pb.getRepeatedField(1, nestedBytes).mapFailure:
    for b in nestedBytes:
      let t = ? T.decode(b)
      ts.add(t)

  success(ts)

proc autoencode*[T: tuple | object](tup: T): seq[byte] =
  var
    pb = initProtoBuffer(maxSize = MaxBufferSize)
    index = 1
  for f in fields(tup):
    when (compiles do:
        let _: seq[byte] = encode(f)):
      let fBytes = encode(f)
      pb.write(index, fBytes)
      index.inc
    else:
      {.error: "provide `proc encode(a: " & $typeof(f) & "): seq[byte]` to use autoencode".}

  pb.finish
  pb.buffer

proc autodecode*(T: typedesc[tuple | object], bytes: seq[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes, maxSize = MaxBufferSize)
    res = default(T)
    index = 1
  for f in fields(res):
    var buf = newSeq[byte]()
    discard ? pb.getField(index, buf).mapFailure
    f = ? decode(typeof(f), buf)
    index.inc

  success(res)
