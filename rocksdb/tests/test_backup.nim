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
  ../rocksdb/backup,
  ./test_helper

suite "BackupEngineRef Tests":

  let
    key = @[byte(1), 2, 3, 4, 5]
    val = @[byte(1), 2, 3, 4, 5]

  setup:
    let
      dbPath = mkdtemp() / "data"
      dbBackupPath = mkdtemp() / "backup"
      dbRestorePath =  mkdtemp() / "restore"

    var
      db = initReadWriteDb(dbPath)

  teardown:

    db.close()
    removeDir($dbPath)
    removeDir($dbBackupPath)


  test "Test backup":
    var engine = initBackupEngine(dbBackupPath)

    check:
      db.put(key, val).isOk()
      db.keyExists(key).value()

    check engine.createNewBackup(db).isOk()

    check:
      db.delete(key).isOk()
      not db.keyExists(key).value()

    check engine.restoreDbFromLatestBackup(dbRestorePath).isOk()

    let db2 = initReadWriteDb(dbRestorePath)
    check db2.keyExists(key).value()

    engine.close()

  test "Test close":
    let res = openBackupEngine(dbPath)
    doAssert res.isOk()
    var engine = res.get()

    check not engine.isClosed()
    engine.close()
    check engine.isClosed()
    engine.close()
    check engine.isClosed()
