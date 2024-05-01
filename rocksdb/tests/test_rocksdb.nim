# Nim-RocksDB
# Copyright 2018-2024 Status Research & Development GmbH
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
  ../rocksdb/rocksdb,
  ./test_helper

suite "RocksDbRef Tests":
  const
    CF_DEFAULT = "default"
    CF_OTHER = "other"

  let
    key = @[byte(1), 2, 3, 4, 5]
    otherKey = @[byte(1), 2, 3, 4, 5, 6]
    val = @[byte(1), 2, 3, 4, 5]

  setup:
    let
      dbPath = mkdtemp() / "data"
      db = initReadWriteDb(dbPath, columnFamilyNames = @[CF_DEFAULT, CF_OTHER])

  teardown:
    db.close()
    removeDir($dbPath)

  test "Basic operations":

    var s = db.put(key, val)
    check s.isOk()

    var bytes: seq[byte]
    check db.get(key, proc(data: openArray[byte]) = bytes = @data)[]
    check not db.get(otherkey, proc(data: openArray[byte]) = bytes = @data)[]

    var r1 = db.get(key)
    check r1.isOk() and r1.value == val

    var r2 = db.get(otherKey)
    # there's no error string for missing keys
    check r2.isOk() == false and r2.error.len == 0

    var e1 = db.keyExists(key)
    check e1.isOk() and e1.value == true

    var e2 = db.keyExists(otherKey)
    check e2.isOk() and e2.value == false

    var d = db.delete(key)
    check d.isOk()

    e1 = db.keyExists(key)
    check e1.isOk() and e1.value == false

    d = db.delete(otherKey)
    check d.isOk()

    close(db)
    check db.isClosed()

    # Open database in read only mode
    block:
      var
        readOnlyDb = initReadOnlyDb(dbPath)
        r = readOnlyDb.keyExists(key)
      check r.isOk() and r.value == false

      # This won't compile as designed:
      # var r2 = readOnlyDb.put(key, @[123.byte])
      # check r2.isErr()

      readOnlyDb.close()
      check readOnlyDb.isClosed()

  test "Basic operations - default column family":

    var s = db.put(key, val, CF_DEFAULT)
    check s.isOk()

    var bytes: seq[byte]
    check db.get(key, proc(data: openArray[byte]) = bytes = @data, CF_DEFAULT)[]
    check not db.get(otherkey, proc(data: openArray[byte]) = bytes = @data, CF_DEFAULT)[]

    var r1 = db.get(key)
    check r1.isOk() and r1.value == val

    var r2 = db.get(otherKey)
    # there's no error string for missing keys
    check r2.isOk() == false and r2.error.len == 0

    var e1 = db.keyExists(key, CF_DEFAULT)
    check e1.isOk() and e1.value == true

    var e2 = db.keyExists(otherKey, CF_DEFAULT)
    check e2.isOk() and e2.value == false

    var d = db.delete(key, CF_DEFAULT)
    check d.isOk()

    e1 = db.keyExists(key, CF_DEFAULT)
    check e1.isOk() and e1.value == false

    d = db.delete(otherKey, CF_DEFAULT)
    check d.isOk()

    close(db)
    check db.isClosed()

    # Open database in read only mode
    block:
      var
        readOnlyDb = initReadOnlyDb(dbPath, columnFamilyNames = @[CF_DEFAULT])
        r = readOnlyDb.keyExists(key, CF_DEFAULT)
      check r.isOk() and r.value == false

      # Won't compile as designed:
      # var r2 = readOnlyDb.put(key, @[123.byte], CF_DEFAULT)
      # check r2.isErr()

      readOnlyDb.close()
      check readOnlyDb.isClosed()

  test "Basic operations - multiple column families":

    var s = db.put(key, val, CF_DEFAULT)
    check s.isOk()

    var s2 = db.put(otherKey, val, CF_OTHER)
    check s2.isOk()

    var bytes: seq[byte]
    check db.get(key, proc(data: openArray[byte]) = bytes = @data, CF_DEFAULT)[]
    check not db.get(otherkey, proc(data: openArray[byte]) = bytes = @data, CF_DEFAULT)[]

    var bytes2: seq[byte]
    check db.get(otherKey, proc(data: openArray[byte]) = bytes2 = @data, CF_OTHER)[]
    check not db.get(key, proc(data: openArray[byte]) = bytes2 = @data, CF_OTHER)[]

    var e1 = db.keyExists(key, CF_DEFAULT)
    check e1.isOk() and e1.value == true
    var e2 = db.keyExists(otherKey, CF_DEFAULT)
    check e2.isOk() and e2.value == false

    var e3 = db.keyExists(key, CF_OTHER)
    check e3.isOk() and e3.value == false
    var e4 = db.keyExists(otherKey, CF_OTHER)
    check e4.isOk() and e4.value == true

    var d = db.delete(key, CF_DEFAULT)
    check d.isOk()
    e1 = db.keyExists(key, CF_DEFAULT)
    check e1.isOk() and e1.value == false
    d = db.delete(otherKey, CF_DEFAULT)
    check d.isOk()

    var d2 = db.delete(key, CF_OTHER)
    check d2.isOk()
    e3 = db.keyExists(key, CF_OTHER)
    check e3.isOk() and e3.value == false
    d2 = db.delete(otherKey, CF_OTHER)
    check d2.isOk()
    d2 = db.delete(otherKey, CF_OTHER)
    check d2.isOk()

    db.close()
    check db.isClosed()

    # Open database in read only mode
    block:
      var
        readOnlyDb = initReadOnlyDb(dbPath, columnFamilyNames = @[CF_DEFAULT, CF_OTHER])

      var r = readOnlyDb.keyExists(key, CF_OTHER)
      check r.isOk() and r.value == false

      # Does not compile as designed:
      # var r2 = readOnlyDb.put(key, @[123.byte], CF_OTHER)
      # check r2.isErr()

      readOnlyDb.close()
      check readOnlyDb.isClosed()

  test "Close multiple times":

    check not db.isClosed()
    db.close()
    check db.isClosed()
    db.close()
    check db.isClosed()

  test "Unknown column family":
    const CF_UNKNOWN = "unknown"

    let r = db.put(key, val, CF_UNKNOWN)
    check r.isErr() and r.error() == "rocksdb: unknown column family"

    var bytes: seq[byte]
    let r2 = db.get(key, proc(data: openArray[byte]) = bytes = @data, CF_UNKNOWN)
    check r2.isErr() and r2.error() == "rocksdb: unknown column family"

    let r3 = db.keyExists(key, CF_UNKNOWN)
    check r3.isErr() and r3.error() == "rocksdb: unknown column family"

    let r4 = db.delete(key, CF_UNKNOWN)
    check r4.isErr() and r4.error() == "rocksdb: unknown column family"

  test "Test missing key and values":
    let
      key1 = @[byte(1)] # exists with non empty value
      val1 = @[byte(1)]
      key2 = @[byte(2)] # exists with empty seq value
      val2: seq[byte] = @[]
      key3 = @[byte(3)] # exists with empty array value
      val3: array[0, byte] = []
      key4 = @[byte(4)] # deleted key
      key5 = @[byte(5)] # key not created

    check:
      db.put(key1, val1).isOk()
      db.put(key2, val2).isOk()
      db.put(key3, val3).isOk()
      db.delete(key4).isOk()

      db.keyExists(key1).get() == true
      db.keyExists(key2).get() == true
      db.keyExists(key3).get() == true
      db.keyExists(key4).get() == false
      db.keyExists(key5).get() == false

    block:
      var v: seq[byte]
      let r = db.get(key1, proc(data: openArray[byte]) = v = @data)
      check:
        r.isOk()
        r.value() == true
        v == val1
        db.get(key1).isOk()

    block:
      var v: seq[byte]
      let r = db.get(key2, proc(data: openArray[byte]) = v = @data)
      check:
        r.isOk()
        r.value() == true
        v.len() == 0
        db.get(key2).isOk()

    block:
      var v: seq[byte]
      let r = db.get(key3, proc(data: openArray[byte]) = v = @data)
      check:
        r.isOk()
        r.value() == true
        v.len() == 0
        db.get(key3).isOk()

    block:
      var v: seq[byte]
      let r = db.get(key4, proc(data: openArray[byte]) = v = @data)
      check:
        r.isOk()
        r.value() == false
        v.len() == 0
        db.get(key4).isErr()

    block:
      var v: seq[byte]
      let r = db.get(key5, proc(data: openArray[byte]) = v = @data)
      check:
        r.isOk()
        r.value() == false
        v.len() == 0
        db.get(key5).isErr()
