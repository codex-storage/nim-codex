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
  ../rocksdb/columnfamily,
  ./test_helper

suite "ColFamily Tests":
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
    let r0 = db.withColFamily(CF_OTHER)
    check r0.isOk()
    let cf = r0.value()

    check cf.put(key, val).isOk()

    var bytes: seq[byte]
    check cf.get(key, proc(data: openArray[byte]) = bytes = @data)[]
    check not cf.get(otherkey, proc(data: openArray[byte]) = bytes = @data)[]

    var r1 = cf.get(key)
    check r1.isOk() and r1.value == val

    var r2 = cf.get(otherKey)
    # there's no error string for missing keys
    check r2.isOk() == false and r2.error.len == 0

    var e1 = cf.keyExists(key)
    check e1.isOk() and e1.value == true

    var e2 = cf.keyExists(otherKey)
    check e2.isOk() and e2.value == false

    var d = cf.delete(key)
    check d.isOk()

    e1 = cf.keyExists(key)
    check e1.isOk() and e1.value == false

    d = cf.delete(otherKey)
    check d.isOk()

    cf.db.close()
    check db.isClosed()

    # Open database in read only mode
    block:
      var res = initReadOnlyDb(dbPath).withColFamily(CF_DEFAULT)
      check res.isOk()

      let readOnlyCf = res.value()
      let r = readOnlyCf.keyExists(key)
      check r.isOk() and r.value == false

      readOnlyCf.db.close()
      check readOnlyCf.db.isClosed()
