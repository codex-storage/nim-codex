import std/options
import std/sequtils
import std/strutils
import std/sugar
import std/typetraits

import pkg/chronicles
import pkg/faststreams
from pkg/libp2p import Cid, MultiAddress, `$`
import pkg/questionable
import pkg/stew/byteutils
import pkg/stint
import pkg/upraises

export byteutils
export chronicles except toJson, formatIt
export questionable
export sequtils
export strutils
export sugar
export upraises

func shortLog*(long: string, ellipses = "*", start = 3, stop = 6): string =
  ## Returns compact string representation of ``long``.
  var short = long
  let minLen = start + ellipses.len + stop
  if len(short) > minLen:
    short.insert(ellipses, start)

    when (NimMajor, NimMinor) > (1, 4):
      short.delete(start + ellipses.len .. short.high - stop)
    else:
      short.delete(start + ellipses.len, short.high - stop)

  short

func shortHexLog*(long: string): string =
  if long[0..1] == "0x": result &= "0x"
  result &= long[2..long.high].shortLog("..", 4, 4)

func short0xHexLog*[N: static[int], T: array[N, byte]](v: T): string =
  v.to0xHex.shortHexLog

func short0xHexLog*[T: distinct](v: T): string =
  type BaseType = T.distinctBase
  BaseType(v).short0xHexLog

func short0xHexLog*[U: distinct, T: seq[U]](v: T): string =
  type BaseType = U.distinctBase
  "@[" & v.map(x => BaseType(x).short0xHexLog).join(",") & "]"

proc formatSeq*(val: seq[string]): string =
  "@[" & val.join(", ") & "]"

template formatOption*(val, T, body): auto =
  var v = "None(" & $T & ")"
  if it =? val:
    v = "Some(" & body & ")" # that I used to know :)
  v

template formatIt*(T: type, body: untyped) {.dirty.} =
  chronicles.formatIt(T, body)

  proc writeValue*(writer: var JsonWriter, it: T) {.upraises:[IOError].} =
    let formatted = body
    writer.writeValue(formatted)

  proc setProperty*(r: var JsonRecord, key: string, it: T) =
    let v = body
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, val: ?T) =
    setProperty(r, key, val.formatOption(T, body))

  proc setProperty*(r: var TextLineRecord, key: string, val: seq[?T]) =
    let v = val.map(item => item.formatOption(T, body)).formatSeq
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, val: seq[T]) =
    let v = val.map(it => body).formatSeq
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, it: T) =
    let v = body
    setProperty(r, key, v)

formatIt(Cid): shortLog($it)
formatIt(UInt256): $it
formatIt(MultiAddress): $it
