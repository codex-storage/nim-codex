# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## A `RocksDBRef` represents a reference to a RocksDB instance. It can be opened
## in read-only or read-write mode in which case a `RocksDbReadOnlyRef` or
## `RocksDbReadWriteRef` will be returned respectively. The `RocksDbReadOnlyRef`
## type doesn't support any of the write operations such as `put`, `delete` or
## `write`.
##
## Many of the operations on these types can potentially fail for various reasons,
## in which case a `RocksDbResult` containing an error will be returned.
##
## The types wrap and hold a handle to a c pointer which needs to be freed
## so `close` should be called to prevent a memory leak after use.
##
## Most of the procs below support passing in the name of the column family
## which should be used for the operation. The default column family will be
## used if none is provided.

{.push raises: [].}

import
  std/[sequtils, locks],
  ./lib/librocksdb,
  ./options/[dbopts, readopts, writeopts],
  ./columnfamily/[cfopts, cfdescriptor, cfhandle],
  ./internal/[cftable, utils],
  ./rocksiterator,
  ./rocksresult,
  ./writebatch

export
  rocksresult,
  dbopts,
  readopts,
  writeopts,
  cfdescriptor,
  rocksiterator,
  writebatch

type
  RocksDbPtr* = ptr rocksdb_t
  IngestExternalFilesOptionsPtr = ptr rocksdb_ingestexternalfileoptions_t

  RocksDbRef* = ref object of RootObj
    lock: Lock
    cPtr: RocksDbPtr
    path: string
    dbOpts: DbOptionsRef
    readOpts: ReadOptionsRef
    defaultCfName: string
    cfTable: ColFamilyTableRef

  RocksDbReadOnlyRef* = ref object of RocksDbRef

  RocksDbReadWriteRef* = ref object of RocksDbRef
    writeOpts: WriteOptionsRef
    ingestOptsPtr: IngestExternalFilesOptionsPtr

proc openRocksDb*(
    path: string,
    dbOpts = defaultDbOptions(),
    readOpts = defaultReadOptions(),
    writeOpts = defaultWriteOptions(),
    columnFamilies: openArray[ColFamilyDescriptor] = []): RocksDBResult[RocksDbReadWriteRef] =
  ## Open a RocksDB instance in read-write mode. If `columnFamilies` is empty
  ## then it will open the default column family. If `dbOpts`, `readOpts`, or
  ## `writeOpts` are not supplied then the default options will be used.
  ## By default, column families will be created if they don't yet exist.
  ## All existing column families must be specified if the database has
  ## previously created any column families.

  var cfs = columnFamilies.toSeq()
  if DEFAULT_COLUMN_FAMILY_NAME notin columnFamilies.mapIt(it.name()):
    cfs.add(defaultColFamilyDescriptor())

  var
    cfNames = cfs.mapIt(it.name().cstring)
    cfOpts = cfs.mapIt(it.options.cPtr)
    cfHandles = newSeq[ColFamilyHandlePtr](cfs.len)
    errors: cstring
  let rocksDbPtr = rocksdb_open_column_families(
        dbOpts.cPtr,
        path.cstring,
        cfNames.len().cint,
        cast[cstringArray](cfNames[0].addr),
        cfOpts[0].addr,
        cfHandles[0].addr,
        cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  let db = RocksDbReadWriteRef(
      lock: createLock(),
      cPtr: rocksDbPtr,
      path: path,
      dbOpts: dbOpts,
      readOpts: readOpts,
      writeOpts: writeOpts,
      ingestOptsPtr: rocksdb_ingestexternalfileoptions_create(),
      defaultCfName: DEFAULT_COLUMN_FAMILY_NAME,
      cfTable: newColFamilyTable(cfNames.mapIt($it), cfHandles))
  ok(db)

proc openRocksDbReadOnly*(
    path: string,
    dbOpts = defaultDbOptions(),
    readOpts = defaultReadOptions(),
    columnFamilies: openArray[ColFamilyDescriptor] = [],
    errorIfWalFileExists = false): RocksDBResult[RocksDbReadOnlyRef] =
  ## Open a RocksDB instance in read-only mode. If `columnFamilies` is empty
  ## then it will open the default column family. If `dbOpts` or `readOpts` are
  ## not supplied then the default options will be used. By default, column
  ## families will be created if they don't yet exist. If the database already
  ## contains any column families, then all or a subset of the existing column
  ## families can be opened for reading.

  var cfs = columnFamilies.toSeq()
  if DEFAULT_COLUMN_FAMILY_NAME notin columnFamilies.mapIt(it.name()):
    cfs.add(defaultColFamilyDescriptor())

  var
    cfNames = cfs.mapIt(it.name().cstring)
    cfOpts = cfs.mapIt(it.options.cPtr)
    cfHandles = newSeq[ColFamilyHandlePtr](cfs.len)
    errors: cstring
  let rocksDbPtr = rocksdb_open_for_read_only_column_families(
        dbOpts.cPtr,
        path.cstring,
        cfNames.len().cint,
        cast[cstringArray](cfNames[0].addr),
        cfOpts[0].addr,
        cfHandles[0].addr,
        errorIfWalFileExists.uint8,
        cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  let db = RocksDbReadOnlyRef(
      lock: createLock(),
      cPtr: rocksDbPtr,
      path: path,
      dbOpts: dbOpts,
      readOpts: readOpts,
      defaultCfName: DEFAULT_COLUMN_FAMILY_NAME,
      cfTable: newColFamilyTable(cfNames.mapIt($it), cfHandles))
  ok(db)

proc isClosed*(db: RocksDbRef): bool {.inline.} =
  ## Returns `true` if the database has been closed and `false` otherwise.
  db.cPtr.isNil()

proc cPtr*(db: RocksDbRef): RocksDbPtr {.inline.} =
  ## Get the underlying database pointer.
  doAssert not db.isClosed()
  db.cPtr

proc get*(
    db: RocksDbRef,
    key: openArray[byte],
    onData: DataProc,
    columnFamily = db.defaultCfName): RocksDBResult[bool] =
  ## Get the value for the given key from the specified column family.
  ## If the value does not exist, `false` will be returned in the result
  ## and `onData` will not be called. If the value does exist, `true` will be
  ## returned in the result and `onData` will be called with the value.
  ## The `onData` callback reduces the number of copies and therefore should be
  ## preferred if performance is required.

  if key.len() == 0:
    return err("rocksdb: key is empty")

  let cfHandle = db.cfTable.get(columnFamily)
  if cfHandle.isNil():
    return err("rocksdb: unknown column family")

  var
    len: csize_t
    errors: cstring
  let data = rocksdb_get_cf(
        db.cPtr,
        db.readOpts.cPtr,
        cfHandle.cPtr,
        cast[cstring](unsafeAddr key[0]),
        csize_t(key.len),
        len.addr,
        cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  if data.isNil():
    doAssert len == 0
    ok(false)
  else:
    onData(toOpenArrayByte(data, 0, len.int - 1))
    rocksdb_free(data)
    ok(true)

proc get*(
    db: RocksDbRef,
    key: openArray[byte],
    columnFamily = db.defaultCfName): RocksDBResult[seq[byte]] =
  ## Get the value for the given key from the specified column family.
  ## If the value does not exist, an empty error will be returned in the result.
  ## If the value does exist, the value will be returned in the result.

  var dataRes: RocksDBResult[seq[byte]]
  proc onData(data: openArray[byte]) = dataRes.ok(@data)

  let res = db.get(key, onData, columnFamily)
  if res.isOk():
    return dataRes

  dataRes.err(res.error())

proc put*(
    db: RocksDbReadWriteRef,
    key, val: openArray[byte],
    columnFamily = db.defaultCfName): RocksDBResult[void] =
  ## Put the value for the given key into the specified column family.

  if key.len() == 0:
    return err("rocksdb: key is empty")

  let cfHandle = db.cfTable.get(columnFamily)
  if cfHandle.isNil():
    return err("rocksdb: unknown column family")

  var errors: cstring
  rocksdb_put_cf(
      db.cPtr,
      db.writeOpts.cPtr,
      cfHandle.cPtr,
      cast[cstring](unsafeAddr key[0]),
      csize_t(key.len),
      cast[cstring](if val.len > 0: unsafeAddr val[0] else: nil),
      csize_t(val.len),
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc keyExists*(
    db: RocksDbRef,
    key: openArray[byte],
    columnFamily = db.defaultCfName): RocksDBResult[bool] =
  ## Check if the key exists in the specified column family.
  ## Returns a result containing `true` if the key exists or a result
  ## containing `false` otherwise.

  # TODO: Call rocksdb_key_may_exist_cf to improve performance for the case
  # when the key does not exist

  db.get(key, proc(data: openArray[byte]) = discard, columnFamily)

proc delete*(
    db: RocksDbReadWriteRef,
    key: openArray[byte],
    columnFamily = db.defaultCfName): RocksDBResult[void] =
  ## Delete the value for the given key from the specified column family.
  ## If the value does not exist, the delete will be a no-op.
  ## To check if the value exists before or after a delete, use `keyExists`.

  if key.len() == 0:
    return err("rocksdb: key is empty")

  let cfHandle = db.cfTable.get(columnFamily)
  if cfHandle.isNil:
    return err("rocksdb: unknown column family")

  var errors: cstring
  rocksdb_delete_cf(
      db.cPtr,
      db.writeOpts.cPtr,
      cfHandle.cPtr,
      cast[cstring](unsafeAddr key[0]),
      csize_t(key.len),
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc openIterator*(
    db: RocksDbRef,
    columnFamily = db.defaultCfName): RocksDBResult[RocksIteratorRef] =
  ## Opens an `RocksIteratorRef` for the specified column family.
  doAssert not db.isClosed()

  let cfHandle  = db.cfTable.get(columnFamily)
  if cfHandle.isNil():
    return err("rocksdb: unknown column family")

  let rocksIterPtr = rocksdb_create_iterator_cf(
        db.cPtr,
        db.readOpts.cPtr,
        cfHandle.cPtr)

  ok(newRocksIterator(rocksIterPtr))

proc openWriteBatch*(
    db: RocksDbReadWriteRef,
    columnFamily = db.defaultCfName): WriteBatchRef =
  ## Opens a `WriteBatchRef` which defaults to using the specified column family.
  doAssert not db.isClosed()

  newWriteBatch(db.cfTable, columnFamily)

proc write*(
    db: RocksDbReadWriteRef,
    updates: WriteBatchRef): RocksDBResult[void] =
  ## Apply the updates in the `WriteBatchRef` to the database.
  doAssert not db.isClosed()

  var errors: cstring
  rocksdb_write(
      db.cPtr,
      db.writeOpts.cPtr,
      updates.cPtr,
      cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc ingestExternalFile*(
    db: RocksDbReadWriteRef,
    filePath: string,
    columnFamily = db.defaultCfName): RocksDbResult[void] =
  ## Ingest an external sst file into the database. The file will be ingested
  ## into the specified column family or the default column family if none is
  ## provided.
  doAssert not db.isClosed()

  let cfHandle  = db.cfTable.get(columnFamily)
  if cfHandle.isNil():
    return err("rocksdb: unknown column family")

  var
    sstPath = filePath.cstring
    errors: cstring
  rocksdb_ingest_external_file_cf(
    db.cPtr,
    cfHandle.cPtr,
    cast[cstringArray](sstPath.addr), csize_t(1),
    db.ingestOptsPtr,
    cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc close*(db: RocksDbRef) =
  ## Close the `RocksDbRef` which will release the connection to the database
  ## and free the memory associated with it. `close` is idempotent and can
  ## safely be called multple times. `close` is a no-op if the `RocksDbRef`
  ## is already closed.

  withLock(db.lock):
    if not db.isClosed():
      db.dbOpts.close()
      db.readOpts.close()
      db.cfTable.close()

      if db of RocksDbReadWriteRef:
        let db = RocksDbReadWriteRef(db)
        db.writeOpts.close()
        rocksdb_ingestexternalfileoptions_destroy(db.ingestOptsPtr)
        db.ingestOptsPtr = nil

      rocksdb_close(db.cPtr)
      db.cPtr = nil
