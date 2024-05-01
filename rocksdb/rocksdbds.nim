import std/times
import std/options

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/sqlite3_abi
from pkg/stew/results as stewResults import isErr
import pkg/upraises

import pkg/datastore

push: {.upraises: [].}

type
  RocksDbDatastore* = ref object of Datastore
    a: string

method get*(self: RocksDbDatastore, key: Key): Future[?!seq[byte]] {.async, locks: "unknown".} =
  raiseAssert("a")

method put*(self: RocksDbDatastore, key: Key, data: seq[byte]): Future[?!void] {.async, locks: "unknown".} =
  raiseAssert("a")

proc new*(T: type RocksDbDatastore, dbName: string): ?!T =
  raiseAssert("a")
