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
  std/os,
  tempfile,
  unittest2,
  ../rocksdb/[transactiondb],
  ./test_helper

suite "TransactionDbRef Tests":

  const
    CF_DEFAULT = "default"
    CF_OTHER = "other"

  let
    key1 = @[byte(1)]
    val1 = @[byte(1)]
    key2 = @[byte(2)]
    val2 = @[byte(2)]
    key3 = @[byte(3)]
    val3 = @[byte(3)]

  setup:
    let dbPath = mkdtemp() / "data"
    var db = initTransactionDb(dbPath, columnFamilyNames = @[CF_OTHER])

  teardown:
    db.close()
    removeDir($dbPath)

# test multiple transactions

  test "Test rollback using default column family":
    var tx = db.beginTransaction()
    defer: tx.close()
    check not tx.isClosed()

    check:
      tx.put(key1, val1).isOk()
      tx.put(key2, val2).isOk()
      tx.put(key3, val3).isOk()

      tx.delete(key2).isOk()
      not tx.isClosed()

    check:
      tx.get(key1).get() == val1
      tx.get(key2).error() == ""
      tx.get(key3).get() == val3

    let res = tx.rollback()
    check:
      res.isOk()
      tx.get(key1).error() == ""
      tx.get(key2).error() == ""
      tx.get(key3).error() == ""

  test "Test commit using default column family":
    var tx = db.beginTransaction()
    defer: tx.close()
    check not tx.isClosed()

    check:
      tx.put(key1, val1).isOk()
      tx.put(key2, val2).isOk()
      tx.put(key3, val3).isOk()

      tx.delete(key2).isOk()
      not tx.isClosed()

    check:
      tx.get(key1).get() == val1
      tx.get(key2).error() == ""
      tx.get(key3).get() == val3

    let res = tx.commit()
    check:
      res.isOk()
      tx.get(key1).get() == val1
      tx.get(key2).error() == ""
      tx.get(key3).get() == val3

  test "Test setting column family in beginTransaction":
    var tx = db.beginTransaction(columnFamily = CF_OTHER)
    defer: tx.close()
    check not tx.isClosed()

    check:
      tx.put(key1, val1).isOk()
      tx.put(key2, val2).isOk()
      tx.put(key3, val3).isOk()

      tx.delete(key2).isOk()
      not tx.isClosed()

    check:
      tx.get(key1, CF_DEFAULT).error() == ""
      tx.get(key2, CF_DEFAULT).error() == ""
      tx.get(key3, CF_DEFAULT).error() == ""
      tx.get(key1, CF_OTHER).get() == val1
      tx.get(key2, CF_OTHER).error() == ""
      tx.get(key3, CF_OTHER).get() == val3


  test "Test rollback and commit with multiple transactions":
    var tx1 = db.beginTransaction(columnFamily = CF_DEFAULT)
    defer: tx1.close()
    check not tx1.isClosed()
    var tx2 = db.beginTransaction(columnFamily = CF_OTHER)
    defer: tx2.close()
    check not tx2.isClosed()

    check:
      tx1.put(key1, val1).isOk()
      tx1.put(key2, val2).isOk()
      tx1.put(key3, val3).isOk()
      tx1.delete(key2).isOk()
      not tx1.isClosed()
      tx2.put(key1, val1).isOk()
      tx2.put(key2, val2).isOk()
      tx2.put(key3, val3).isOk()
      tx2.delete(key2).isOk()
      not tx2.isClosed()

    check:
      tx1.get(key1, CF_DEFAULT).get() == val1
      tx1.get(key2, CF_DEFAULT).error() == ""
      tx1.get(key3, CF_DEFAULT).get() == val3
      tx1.get(key1, CF_OTHER).error() == ""
      tx1.get(key2, CF_OTHER).error() == ""
      tx1.get(key3, CF_OTHER).error() == ""

      tx2.get(key1, CF_DEFAULT).error() == ""
      tx2.get(key2, CF_DEFAULT).error() == ""
      tx2.get(key3, CF_DEFAULT).error() == ""
      tx2.get(key1, CF_OTHER).get() == val1
      tx2.get(key2, CF_OTHER).error() == ""
      tx2.get(key3, CF_OTHER).get() == val3

    block:
      let res = tx1.rollback()
      check:
        res.isOk()
        tx1.get(key1, CF_DEFAULT).error() == ""
        tx1.get(key2, CF_DEFAULT).error() == ""
        tx1.get(key3, CF_DEFAULT).error() == ""
        tx1.get(key1, CF_OTHER).error() == ""
        tx1.get(key2, CF_OTHER).error() == ""
        tx1.get(key3, CF_OTHER).error() == ""

    block:
      let res = tx2.commit()
      check:
        res.isOk()
        tx2.get(key1, CF_DEFAULT).error() == ""
        tx2.get(key2, CF_DEFAULT).error() == ""
        tx2.get(key3, CF_DEFAULT).error() == ""
        tx2.get(key1, CF_OTHER).get() == val1
        tx2.get(key2, CF_OTHER).error() == ""
        tx2.get(key3, CF_OTHER).get() == val3

  test "Test close":
    var tx = db.beginTransaction()

    check not tx.isClosed()
    tx.close()
    check tx.isClosed()
    tx.close()
    check tx.isClosed()

    check not db.isClosed()
    db.close()
    check db.isClosed()
    db.close()
    check db.isClosed()

  test "Test close multiple tx":
    var tx1 = db.beginTransaction()
    var tx2 = db.beginTransaction()

    check not db.isClosed()
    check not tx1.isClosed()
    tx1.close()
    check tx1.isClosed()
    tx1.close()
    check tx1.isClosed()

    check not db.isClosed()
    check not tx2.isClosed()
    tx2.close()
    check tx2.isClosed()
    tx2.close()
    check tx2.isClosed()
