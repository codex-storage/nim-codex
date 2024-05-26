import std/times
import std/options

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/sqlite3_abi
from pkg/stew/results as stewResults import isErr
import pkg/upraises

import pkg/datastore

import ./rocksdb

push: {.upraises: [].}

type
  RocksDbDatastore* = ref object of Datastore
    db: RocksDbReadWriteRef

func toByteSeq(str: string): seq[byte] {.inline.} =
  @(str.toOpenArrayByte(0, str.high))

func toString(bytes: openArray[byte]): string {.inline.} =
  let length = bytes.len
  if length > 0:
    result = newString(length)
    copyMem(result.cstring, bytes[0].unsafeAddr, length)

method get*(self: RocksDbDatastore, key: Key): Future[?!seq[byte]] {.async, locks: "unknown".} =
  let keyBytes = toByteSeq($key)

  let res = self.db.get(keyBytes)
  if res.isErr():
    return failure(res.error())
  return success(res.value())

method put*(self: RocksDbDatastore, key: Key, data: seq[byte]): Future[?!void] {.async, locks: "unknown".} =
  let keyBytes = toByteSeq($key)
  let res = self.db.put(keyBytes, data)
  if res.isErr():
    return failure("failed to put!")
  return success()

proc new*(T: type RocksDbDatastore, dbName: string): ?!T =
  let res = openRocksDb(dbName)
  if res.isErr():
    return failure(res.error())
  let db = res.value()

  success T(
    db: db
  )
