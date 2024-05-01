# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
    std/sequtils,
  ../rocksdb/backup,
  ../rocksdb/rocksdb,
  ../rocksdb/transactiondb


proc initReadWriteDb*(
    path: string,
    columnFamilyNames: openArray[string] = @[]): RocksDbReadWriteRef =

  let res = openRocksDb(
      path,
      columnFamilies = columnFamilyNames.mapIt(initColFamilyDescriptor(it)))
  if res.isErr():
    echo res.error()
  doAssert res.isOk()
  res.value()

proc initReadOnlyDb*(
    path: string,
    columnFamilyNames: openArray[string] = @[]): RocksDbReadOnlyRef =

  let res = openRocksDbReadOnly(
      path,
      columnFamilies = columnFamilyNames.mapIt(initColFamilyDescriptor(it)))
  if res.isErr():
    echo res.error()
  doAssert res.isOk()
  res.value()

proc initBackupEngine*(path: string): BackupEngineRef =

  let res = openBackupEngine(path)
  doAssert res.isOk()
  res.value()

proc initTransactionDb*(
    path: string,
    columnFamilyNames: openArray[string] = @[]): TransactionDbRef =

  let res = openTransactionDb(
      path,
      columnFamilies = columnFamilyNames.mapIt(initColFamilyDescriptor(it)))
  if res.isErr():
    echo res.error()
  doAssert res.isOk()
  res.value()
