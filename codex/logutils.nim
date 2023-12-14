import std/options
import std/sequtils
import std/strutils
import std/sugar
import std/typetraits

import pkg/chronicles except toJson, `%`
# import pkg/faststreams
from pkg/libp2p import Cid, MultiAddress, `$`
import pkg/questionable
import pkg/stew/byteutils
import pkg/stint
import pkg/upraises

import ./utils/json

export byteutils
export chronicles except toJson, formatIt, `%`
export questionable
export sequtils
export strutils
export sugar
export upraises
export json

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

func to0xHexLog*[T: distinct](v: T): string =
  type BaseType = T.distinctBase
  BaseType(v).to0xHex

func to0xHexLog*[U: distinct, T: seq[U]](v: T): string =
  type BaseType = U.distinctBase
  "@[" & v.map(x => BaseType(x).to0xHex).join(",") & "]"

proc formatTextLineSeq*(val: seq[string]): string =
  "@[" & val.join(", ") & "]"

template formatIt*(format: LogFormat, T: type, body: untyped) {.dirty.} =

  when format == LogFormat.json:
    proc formatJsonOption(val: ?T): JsonNode =
      if it =? val:
        json.`%`(body)
      else:
        newJNull()

    proc setProperty*(r: var JsonRecord, key: string, opt: ?T) =
      let v = opt.formatJsonOption
      setProperty(r, key, v)

    proc setProperty*(r: var JsonRecord, key: string, opts: seq[?T]) =
      let v = opts.map(opt => opt.formatJsonOption)
      setProperty(r, key, json.`%`(v))

    proc setProperty*(r: var JsonRecord, key: string, val: seq[T]) =
      let v = val.map(it => body)
      setProperty(r, key, json.`%`(v))

    proc setProperty*(r: var JsonRecord, key: string, it: T) {.upraises:[ValueError, IOError].} =
      let v = body
      setProperty(r, key, json.`%`(v))

  elif format == LogFormat.textLines:
    proc formatTextLineOption*(val: ?T): string =
      var v = "none(" & $T & ")"
      if it =? val:
        v = "some(" & $(body) & ")" # that I used to know :)
      v

    proc setProperty*(r: var TextLineRecord, key: string, opt: ?T) =
      let v = opt.formatTextLineOption
      setProperty(r, key, v)

    proc setProperty*(r: var TextLineRecord, key: string, opts: seq[?T]) =
      let v = opts.map(opt => opt.formatTextLineOption)
      setProperty(r, key, v.formatTextLineSeq)

    proc setProperty*(r: var TextLineRecord, key: string, val: seq[T]) =
      let v = val.map(it => body)
      setProperty(r, key, v.formatTextLineSeq)

    proc setProperty*(r: var TextLineRecord, key: string, it: T) {.upraises:[ValueError, IOError].} =
      let v = body
      setProperty(r, key, v)

template formatIt*(T: type, body: untyped) {.dirty.} =
  formatIt(LogFormat.textLines, T): body
  formatIt(LogFormat.json, T): body

formatIt(LogFormat.textLines, Cid): shortLog($it)
formatIt(LogFormat.json, Cid): $it
formatIt(UInt256): $it
formatIt(MultiAddress): $it
