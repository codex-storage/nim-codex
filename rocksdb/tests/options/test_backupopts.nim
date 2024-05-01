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
  unittest2,
  ../../rocksdb/options/backupopts

suite "BackupEngineOptionsRef Tests":

  test "Test newBackupEngineOptions":
    var backupOpts = newBackupEngineOptions()

    check not backupOpts.cPtr.isNil()

    backupOpts.close()

  test "Test defaultBackupEngineOptions":
    var backupOpts = defaultBackupEngineOptions()

    check not backupOpts.cPtr.isNil()

    backupOpts.close()

  test "Test close":
    var backupOpts = defaultBackupEngineOptions()

    check not backupOpts.isClosed()
    backupOpts.close()
    check backupOpts.isClosed()
    backupOpts.close()
    check backupOpts.isClosed()