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
  ../rocksdb/[rocksdb, writebatch],
  ./test_helper

suite "WriteBatchRef Tests":

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
    var db = initReadWriteDb(dbPath, columnFamilyNames = @[CF_DEFAULT, CF_OTHER])

  teardown:
    db.close()
    removeDir($dbPath)

  test "Test writing batch to the default column family":
    var batch = db.openWriteBatch()
    defer: batch.close()
    check not batch.isClosed()

    check:
      batch.put(key1, val1).isOk()
      batch.put(key2, val2).isOk()
      batch.put(key3, val3).isOk()
      batch.count() == 3

      batch.delete(key2).isOk()
      batch.count() == 4
      not batch.isClosed()

    let res = db.write(batch)
    check:
      res.isOk()
      db.write(batch).isOk() # test that it's idempotent
      db.get(key1).get() == val1
      db.keyExists(key2).get() == false
      db.get(key3).get() == val3

    batch.clear()
    check:
      batch.count() == 0
      not batch.isClosed()

  test "Test writing batch to column family":
    var batch = db.openWriteBatch()
    defer: batch.close()
    check not batch.isClosed()

    check:
      batch.put(key1, val1, CF_OTHER).isOk()
      batch.put(key2, val2, CF_OTHER).isOk()
      batch.put(key3, val3, CF_OTHER).isOk()
      batch.count() == 3

      batch.delete(key2, CF_OTHER).isOk()
      batch.count() == 4
      not batch.isClosed()

    let res = db.write(batch)
    check:
      res.isOk()
      db.get(key1, CF_OTHER).get() == val1
      db.keyExists(key2, CF_OTHER).get() == false
      db.get(key3, CF_OTHER).get() == val3

    batch.clear()
    check:
      batch.count() == 0
      not batch.isClosed()

  test "Test writing to multiple column families in single batch":
    var batch = db.openWriteBatch()
    defer: batch.close()
    check not batch.isClosed()

    check:
      batch.put(key1, val1).isOk()
      batch.put(key1, val1, CF_OTHER).isOk()
      batch.put(key2, val2, CF_OTHER).isOk()
      batch.put(key3, val3, CF_OTHER).isOk()
      batch.count() == 4

      batch.delete(key2, CF_OTHER).isOk()
      batch.count() == 5
      not batch.isClosed()

    let res = db.write(batch)
    check:
      res.isOk()
      db.get(key1).get() == val1
      db.get(key1, CF_OTHER).get() == val1
      db.keyExists(key2, CF_OTHER).get() == false
      db.get(key3, CF_OTHER).get() == val3

    batch.clear()
    check:
      batch.count() == 0
      not batch.isClosed()

  test "Test writing to multiple column families in multiple batches":
    var batch1 = db.openWriteBatch()
    defer: batch1.close()
    check not batch1.isClosed()

    var batch2 = db.openWriteBatch()
    defer: batch2.close()
    check not batch2.isClosed()

    check:
      batch1.put(key1, val1).isOk()
      batch1.delete(key2, CF_OTHER).isOk()
      batch1.put(key3, val3, CF_OTHER).isOk()
      batch2.put(key1, val1, CF_OTHER).isOk()
      batch2.delete(key1, CF_OTHER).isOk()
      batch2.put(key3, val3).isOk()
      batch1.count() == 3
      batch2.count() == 3

    let res1 = db.write(batch1)
    let res2 = db.write(batch2)
    check:
      res1.isOk()
      res2.isOk()
      db.get(key1).get() == val1
      db.keyExists(key2).get() == false
      db.get(key3).get() == val3
      db.keyExists(key1, CF_OTHER).get() == false
      db.keyExists(key2, CF_OTHER).get() == false
      db.get(key3, CF_OTHER).get() == val3

  test "Test unknown column family":
    const CF_UNKNOWN = "unknown"

    var batch = db.openWriteBatch()
    defer: batch.close()
    check not batch.isClosed()

    let r = batch.put(key1, val1, CF_UNKNOWN)
    check r.isErr() and r.error() == "rocksdb: unknown column family"

    let r2 = batch.delete(key1, CF_UNKNOWN)
    check r2.isErr() and r2.error() == "rocksdb: unknown column family"

  test "Test write empty batch":
    var batch = db.openWriteBatch()
    defer: batch.close()
    check not batch.isClosed()

    check batch.count() == 0
    let res1 = db.write(batch)
    check:
      res1.isOk()
      batch.count() == 0

  test "Test close":
    var batch = db.openWriteBatch()

    check not batch.isClosed()
    batch.close()
    check batch.isClosed()
    batch.close()
    check batch.isClosed()