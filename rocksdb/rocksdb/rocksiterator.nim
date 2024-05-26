# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## A `RocksIteratorRef` is a reference to a RocksDB iterator which supports
## iterating over the key value pairs in a column family.

{.push raises: [].}

import
  ./lib/librocksdb,
  ./internal/utils,
  ./rocksresult

export
  rocksresult

type
  RocksIteratorPtr* = ptr rocksdb_iterator_t

  RocksIteratorRef* = ref object
    cPtr: RocksIteratorPtr

proc newRocksIterator*(cPtr: RocksIteratorPtr): RocksIteratorRef =
  doAssert not cPtr.isNil()
  RocksIteratorRef(cPtr: cPtr)

proc isClosed*(iter: RocksIteratorRef): bool {.inline.} =
  ## Returns `true` if the iterator is closed and `false` otherwise.
  iter.cPtr.isNil()

proc seekToKey*(iter: RocksIteratorRef, key: openArray[byte]) =
  ## Seeks to the `key` argument in the column family. If the return code is
  ## `false`, the iterator has become invalid and should be closed.
  ##
  ## It is not clear what happens when the `key` does not exist in the column
  ## family. The guess is that the interation will proceed at the next key
  ## position. This is suggested by a comment from the GO port at
  ##
  ##    //github.com/DanielMorsing/rocksdb/blob/master/iterator.go:
  ##
  ##    Seek moves the iterator the position of the key given or, if the key
  ##    doesn't exist, the next key that does exist in the database. If the
  ##    key doesn't exist, and there is no next key, the Iterator becomes
  ##    invalid.
  ##
  doAssert not iter.isClosed()
  let (cKey, cLen) = (cast[cstring](unsafeAddr key[0]), csize_t(key.len))
  rocksdb_iter_seek(iter.cPtr, cKey, cLen)

proc seekToFirst*(iter: RocksIteratorRef) =
  ## Seeks to the first entry in the column family.
  doAssert not iter.isClosed()
  rocksdb_iter_seek_to_first(iter.cPtr)

proc seekToLast*(iter: RocksIteratorRef) =
  ## Seeks to the last entry in the column family.
  doAssert not iter.isClosed()
  rocksdb_iter_seek_to_last(iter.cPtr)

proc isValid*(iter: RocksIteratorRef): bool =
  ## Returns `true` if the iterator is valid and `false` otherwise.
  rocksdb_iter_valid(iter.cPtr).bool

proc next*(iter: RocksIteratorRef) =
  ## Seeks to the next entry in the column family.
  rocksdb_iter_next(iter.cPtr)

proc prev*(iter: RocksIteratorRef) =
  ## Seeks to the previous entry in the column family.
  rocksdb_iter_prev(iter.cPtr)

proc key*(iter: RocksIteratorRef, onData: DataProc) =
  ## Returns the current key using the provided `onData` callback.

  var kLen: csize_t
  let kData = rocksdb_iter_key(iter.cPtr, kLen.addr)

  if kData.isNil or kLen == 0:
    onData([])
  else:
    onData(kData.toOpenArrayByte(0, kLen.int - 1))

proc key*(iter: RocksIteratorRef): seq[byte] =
  ## Returns the current key.

  var res: seq[byte]
  proc onData(data: openArray[byte]) =
    res = @data

  iter.key(onData)
  res

proc value*(iter: RocksIteratorRef, onData: DataProc) =
  ## Returns the current value using the provided `onData` callback.

  var vLen: csize_t
  let vData = rocksdb_iter_value(iter.cPtr, vLen.addr)

  if vData.isNil or vLen == 0:
    onData([])
  else:
    onData(vData.toOpenArrayByte(0, vLen.int - 1))

proc value*(iter: RocksIteratorRef): seq[byte] =
  ## Returns the current value.

  var res: seq[byte]
  proc onData(data: openArray[byte]) =
    res = @data

  iter.value(onData)
  res

proc status*(iter: RocksIteratorRef): RocksDBResult[void] =
  ## Returns the status of the iterator.
  doAssert not iter.isClosed()

  var errors: cstring
  rocksdb_iter_get_error(iter.cPtr, cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc close*(iter: RocksIteratorRef) =
  ## Closes the `RocksIteratorRef`.
  if not iter.isClosed():
    rocksdb_iter_destroy(iter.cPtr)
    iter.cPtr = nil

iterator pairs*(iter: RocksIteratorRef): tuple[key: seq[byte], value: seq[byte]] =
  ## Iterates over the key value pairs in the column family yielding them in
  ## the form of a tuple. The iterator is automatically closed after the
  ## iteration.
  doAssert not iter.isClosed()
  defer: iter.close()

  iter.seekToFirst()
  while iter.isValid():
    var
      key: seq[byte]
      value: seq[byte]
    iter.key(proc(data: openArray[byte]) = key = @data)
    iter.value(proc(data: openArray[byte]) = value = @data)

    iter.next()
    yield (key, value)
