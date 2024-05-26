# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## A `TransactionDbRef` can be used to open a connection to the RocksDB database
## with support for transactional operations against multiple column families.
## To create a new transaction call `beginTransaction` which will return a
## `TransactionRef`. To commit or rollback the transaction call `commit` or
## `rollback` on the `TransactionRef` type after applying changes to the transaction.

{.push raises: [].}

import
  std/[sequtils, locks],
  ./lib/librocksdb,
  ./options/[dbopts, readopts, writeopts],
  ./transactions/[transaction, txdbopts, txopts],
  ./columnfamily/[cfopts, cfdescriptor, cfhandle],
  ./internal/[cftable, utils],
  ./rocksresult

export
  dbopts,
  txdbopts,
  cfdescriptor,
  readopts,
  writeopts,
  txopts,
  transaction,
  rocksresult

type
  TransactionDbPtr* = ptr rocksdb_transactiondb_t

  TransactionDbRef* = ref object
    lock: Lock
    cPtr: TransactionDbPtr
    path: string
    dbOpts: DbOptionsRef
    txDbOpts: TransactionDbOptionsRef
    cfTable: ColFamilyTableRef

proc openTransactionDb*(
    path: string,
    dbOpts = defaultDbOptions(),
    txDbOpts = defaultTransactionDbOptions(),
    columnFamilies: openArray[ColFamilyDescriptor] = []): RocksDBResult[TransactionDbRef] =
  ## Open a `TransactionDbRef` with the given options and column families.
  ## If no column families are provided the default column family will be used.
  ## If no options are provided the default options will be used.

  var cfs = columnFamilies.toSeq()
  if DEFAULT_COLUMN_FAMILY_NAME notin columnFamilies.mapIt(it.name()):
    cfs.add(defaultColFamilyDescriptor())

  var
    cfNames = cfs.mapIt(it.name().cstring)
    cfOpts = cfs.mapIt(it.options.cPtr)
    cfHandles = newSeq[ColFamilyHandlePtr](cfs.len)
    errors: cstring

  let txDbPtr = rocksdb_transactiondb_open_column_families(
        dbOpts.cPtr,
        txDbOpts.cPtr,
        path.cstring,
        cfNames.len().cint,
        cast[cstringArray](cfNames[0].addr),
        cfOpts[0].addr,
        cfHandles[0].addr,
        cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  let db = TransactionDbRef(
      lock: createLock(),
      cPtr: txDbPtr,
      path: path,
      dbOpts: dbOpts,
      txDbOpts: txDbOpts,
      cfTable: newColFamilyTable(cfNames.mapIt($it), cfHandles))
  ok(db)

proc isClosed*(db: TransactionDbRef): bool {.inline.} =
  ## Returns `true` if the `TransactionDbRef` has been closed.
  db.cPtr.isNil()

proc beginTransaction*(
    db: TransactionDbRef,
    readOpts = defaultReadOptions(),
    writeOpts = defaultWriteOptions(),
    txOpts = defaultTransactionOptions(),
    columnFamily = DEFAULT_COLUMN_FAMILY_NAME): TransactionRef =
  ## Begin a new transaction against the database. The transaction will default
  ## to using the specified column family. If no column family is specified
  ## then the default column family will be used.
  doAssert not db.isClosed()

  let txPtr = rocksdb_transaction_begin(
        db.cPtr,
        writeOpts.cPtr,
        txOpts.cPtr,
        nil)

  newTransaction(txPtr, readOpts, writeOpts, txOpts, columnFamily, db.cfTable)

proc close*(db: TransactionDbRef) =
  ## Close the `TransactionDbRef`.
  withLock(db.lock):
    if not db.isClosed():
      db.dbOpts.close()
      db.txDbOpts.close()
      db.cfTable.close()

      rocksdb_transactiondb_close(db.cPtr)
      db.cPtr = nil
