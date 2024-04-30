import std/times
import std/options

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/sqlite3_abi
from pkg/stew/results as stewResults import isErr
import pkg/upraises

import pkg/datastore

import ./src/leveldb

push: {.upraises: [].}

type
  LevelDbDatastore* = ref object of Datastore
    db: LevelDb

func toByteSeq(str: string): seq[byte] {.inline.} =
  @(str.toOpenArrayByte(0, str.high))

func toString(bytes: openArray[byte]): string {.inline.} =
  let length = bytes.len
  if length > 0:
    result = newString(length)
    copyMem(result.cstring, bytes[0].unsafeAddr, length)

method get*(self: LevelDbDatastore, key: Key): Future[?!seq[byte]] {.async, locks: "unknown".} =
  try:
    let str = self.db.get($key)
    if not str.isSome:
      return failure("Not some!")
    let bytes = toByteSeq(str.get())
    return success(bytes)
  except LevelDbException:
    return failure("exception get")

method put*(self: LevelDbDatastore, key: Key, data: seq[byte]): Future[?!void] {.async, locks: "unknown".} =
  try:
    let str = toString(data)
    self.db.put($key, str)
    return success()
  except LevelDbException:
    return failure("exception put")

proc new*(
  T: type LevelDbDatastore, dbName: string): ?!T =
  try:
    let db = leveldb.open(dbName)

    success T(
      db: db
    )
  except LevelDbException:
    return failure("exception open")
