# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## A `SstFileWriterRef` is used to create sst files that can be added to the database later.

{.push raises: [].}

import
  ./lib/librocksdb,
  ./internal/utils,
  ./options/dbopts,
  ./rocksresult

export
  rocksresult

type
  SstFileWriterPtr* = ptr rocksdb_sstfilewriter_t
  EnvOptionsPtr = ptr rocksdb_envoptions_t

  SstFileWriterRef* = ref object
    cPtr: SstFileWriterPtr
    envOptsPtr: EnvOptionsPtr
    dbOpts: DbOptionsRef

proc openSstFileWriter*(
    filePath: string,
    dbOpts = defaultDbOptions()): RocksDBResult[SstFileWriterRef] =
  ## Creates a new `SstFileWriterRef` and opens the file at the given `filePath`.
  doAssert not dbOpts.isClosed()

  let envOptsPtr = rocksdb_envoptions_create()
  let writer = SstFileWriterRef(
    cPtr: rocksdb_sstfilewriter_create(envOptsPtr, dbOpts.cPtr),
    envOptsPtr: envOptsPtr,
    dbOpts: dbOpts)

  var errors: cstring
  rocksdb_sstfilewriter_open(
      writer.cPtr,
      filePath.cstring,
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok(writer)

proc isClosed*(writer: SstFileWriterRef): bool {.inline.} =
  ## Returns `true` if the `SstFileWriterRef` is closed and `false` otherwise.
  writer.cPtr.isNil()

proc put*(
    writer: SstFileWriterRef,
    key: openArray[byte],
    val: openArray[byte]): RocksDBResult[void] =
  ## Add a key-value pair to the sst file.

  var errors: cstring
  rocksdb_sstfilewriter_put(
      writer.cPtr,
      cast[cstring](unsafeAddr key[0]), csize_t(key.len),
      cast[cstring](unsafeAddr val[0]), csize_t(val.len),
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc delete*(writer: SstFileWriterRef, key: openArray[byte]): RocksDBResult[void] =
  ## Delete a key-value pair from the sst file.

  var errors: cstring
  rocksdb_sstfilewriter_delete(
      writer.cPtr,
      cast[cstring](unsafeAddr key[0]), csize_t(key.len),
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc finish*(writer: SstFileWriterRef): RocksDBResult[void] =
  ## Finish the process and close the sst file.
  doAssert not writer.isClosed()

  var errors: cstring
  rocksdb_sstfilewriter_finish(writer.cPtr, cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc close*(writer: SstFileWriterRef) =
  ## Closes the `SstFileWriterRef`.
  if not writer.isClosed():
    rocksdb_envoptions_destroy(writer.envOptsPtr)
    writer.envOptsPtr = nil
    rocksdb_sstfilewriter_destroy(writer.cPtr)
    writer.cPtr = nil
