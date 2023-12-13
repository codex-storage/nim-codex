import std/options
import std/sequtils
import std/strutils
import std/sugar
import std/typetraits

import pkg/chronicles except toJson
import pkg/faststreams
from pkg/libp2p import Cid, MultiAddress, `$`
import pkg/questionable
import pkg/stew/byteutils
import pkg/stint
import pkg/upraises

import ./utils/json

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

proc formatTextLineSeq*(val: seq[string]): string =
  "@[" & val.join(", ") & "]"

template formatTextLineOption*(val, T, body): auto =
  var v = "none(" & $T & ")"
  if it =? val:
    v = "some(" & body & ")" # that I used to know :)
  v

template formatJsonOption*(val, T, body): auto =
  var v = none string
  if it =? val:
    v = some body # that I used to know :)
  v

template formatIt*(T: type, body: untyped) {.dirty.} =

  proc setProperty*(r: var JsonRecord, key: string, val: ?T) =
    let v = val.formatJsonOption(T, body)
    setProperty(r, key, %v)

  proc setProperty*(r: var JsonRecord, key: string, val: seq[?T]) =
    let v = val.map(it => it.formatJsonOption(T, body))
    setProperty(r, key, %v)

  proc setProperty*(r: var JsonRecord, key: string, val: seq[T]) =
    let v = val.map(it => body)
    setProperty(r, key, %v)

  proc setProperty*(r: var JsonRecord, key: string, it: T) {.upraises:[IOError].} =
    let v = body
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, val: ?T) =
    setProperty(r, key, val.formatTextLineOption(T, body))

  proc setProperty*(r: var TextLineRecord, key: string, val: seq[?T]) =
    let v = val.map(item => item.formatTextLineOption(T, body)).formatTextLineSeq
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, val: seq[T]) =
    let v = val.map(it => body).formatTextLineSeq
    setProperty(r, key, v)

  proc setProperty*(r: var TextLineRecord, key: string, it: T) {.upraises:[ValueError].} =
    let v = body
    setProperty(r, key, v)

formatIt(Cid): shortLog($it)
formatIt(UInt256): $it
formatIt(MultiAddress): $it
