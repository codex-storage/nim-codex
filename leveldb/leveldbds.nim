import std/options
import std/tables

import pkg/chronicles
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
from pkg/stew/results as stewResults import isErr
import pkg/upraises

import pkg/datastore
import pkg/datastore/defaultimpl

import ./src/leveldb

push: {.upraises: [].}

logScope:
  topics = "LevelDB"

type
  LevelDbDatastore* = ref object of Datastore
    db: LevelDb
    locks: TableRef[Key, AsyncLock]

func toByteSeq(str: string): seq[byte] {.inline.} =
  @(str.toOpenArrayByte(0, str.high))

func toString(bytes: openArray[byte]): string {.inline.} =
  let length = bytes.len
  if length > 0:
    result = newString(length)
    copyMem(result.cstring, bytes[0].unsafeAddr, length)

method has*(self: LevelDbDatastore, key: Key): Future[?!bool] {.async, locks: "unknown".} =
  try:
    let str = self.db.get($key)
    return success(str.isSome)
  except LevelDbException as e:
    return failure("LevelDbDatastore.has exception: " & e.msg)

method delete*(self: LevelDbDatastore, key: Key): Future[?!void] {.async, locks: "unknown".} =
  try:
    self.db.delete($key, sync = true)
    return success()
  except LevelDbException as e:
    return failure("LevelDbDatastore.delete exception: " & e.msg)

method delete*(self: Datastore, keys: seq[Key]): Future[?!void] {.async, locks: "unknown".} =
  for key in keys:
    if err =? (await self.delete(key)).errorOption:
      return failure(err.msg)
  return success()

method get*(self: LevelDbDatastore, key: Key): Future[?!seq[byte]] {.async, locks: "unknown".} =
  trace "Get", key
  try:
    let str = self.db.get($key)
    if not str.isSome:
      return failure(newException(DatastoreKeyNotFound, "LevelDbDatastore.get: key not found " & $key))
    let bytes = toByteSeq(str.get())
    return success(bytes)
  except LevelDbException as e:
    return failure("LevelDbDatastore.get exception: " & $e.msg)

method put*(self: LevelDbDatastore, key: Key, data: seq[byte]): Future[?!void] {.async, locks: "unknown".} =
  trace "Put", key
  try:
    let str = toString(data)
    self.db.put($key, str)
    return success()
  except LevelDbException as e:
    return failure("LevelDbDatastore.put exception: " & $e.msg)

method put*(self: LevelDbDatastore, batch: seq[BatchEntry]): Future[?!void] {.async, locks: "unknown".} =
  for entry in batch:
    if err =? (await self.put(entry.key, entry.data)).errorOption:
      return failure(err.msg)
  return success()

method close*(self: LevelDbDatastore): Future[?!void] {.async, locks: "unknown".} =
  try:
    self.db.close()
    return success()
  except LevelDbException as e:
    return failure("LevelDbDatastore.close exception: " & $e.msg)

# Query* = object
#   key*: Key         # Key to be queried
#   value*: bool      # Flag to indicate if data should be returned
#   limit*: int       # Max items to return - not available in all backends
#   offset*: int      # Offset from which to start querying - not available in all backends
#   sort*: SortOrder  # Sort order - not available in all backends
            # Assending,
            # Descending

# QueryIter* = ref object
#   finished*: bool
#   next*: GetNext = proc(): Future[?!QueryResponse] {.upraises: [], gcsafe, closure.}
#   dispose*: IterDispose
  
# QueryResponse* = tuple[key: ?Key, data: seq[byte]]

proc iterateKeyPrefixToQueue(self: LevelDbDatastore, query: Query, queue: AsyncQueue[(string, string)]): Future[void] {.async.} =
  var
    itemsLeft = query.limit
    skip = query.offset

  for keyStr, valueStr in self.db.iterPrefix(prefix = $(query.key)):
    if skip > 0:
      dec skip
    else:
      await queue.put((keyStr, valueStr))
      if query.offset > 0:
        dec itemsLeft
        if itemsLeft < 1:
          break
  
  # Signal to the iterator loop that we're finished.
  await queue.put(("", ""))

method query*(
  self: LevelDbDatastore,
  query: Query): Future[?!QueryIter] {.async, gcsafe.} =
  
  if not (query.sort == SortOrder.Assending):
    return failure("LevelDbDatastore.query: query.sort is not SortOrder.Ascending. Unsupported.")

  if not query.value:
    return failure("LevelDbDatastore.query: query.value is not true. Unsupported.")

  var
    iter = QueryIter()
    queue = newAsyncQueue[(string, string)](1)

  proc next(): Future[?!QueryResponse] {.async.} =
    if iter.finished:
      return failure(newException(QueryEndedError, "Calling next on a finished query!"))

    let (keyStr, valueStr) = await queue.get()

    if keyStr == "":
      iter.finished = true
      return success (Key.none, EmptyBytes)
    else:
      let key = Key.init(keyStr).expect("LevelDbDatastore.query (next) Failed to create key.")
      return success (key.some, valueStr.toByteSeq())
  
  iter.next = next
  iter.dispose = proc(): Future[?!void] {.async.} =
    return success()

  asyncSpawn self.iterateKeyPrefixToQueue(query, queue)

  return success iter

method modifyGet*(
  self: LevelDbDatastore,
  key: Key,
  fn: ModifyGet): Future[?!seq[byte]] {.async.} =
  var lock: AsyncLock
  try:
    lock = self.locks.mgetOrPut(key, newAsyncLock())
    return await defaultModifyGetImpl(self, lock, key, fn)
  finally:
    if not lock.locked:
      self.locks.del(key)

method modify*(
  self: LevelDbDatastore,
  key: Key,
  fn: Modify): Future[?!void] {.async.} =
  var lock: AsyncLock
  try:
    lock = self.locks.mgetOrPut(key, newAsyncLock())
    return await defaultModifyImpl(self, lock, key, fn)
  finally:
    if not lock.locked:
      self.locks.del(key)

proc new*(
  T: type LevelDbDatastore, dbName: string): ?!T =
  try:
    trace "Opening LevelDB", dbName

    let db = leveldb.open(dbName)

    success T(
      db: db,
      locks: newTable[Key, AsyncLock]()
    )
  except LevelDbException:
    error "That didn't work"
    return failure("exception open")
