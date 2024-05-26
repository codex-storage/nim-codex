# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## A `BackupEngineRef` is used to create and manage backups against a RocksDB database.

{.push raises: [].}

import
  ./lib/librocksdb,
  ./internal/utils,
  ./options/backupopts,
  ./rocksdb,
  ./rocksresult

export
  backupopts,
  rocksdb,
  rocksresult

type
  BackupEnginePtr* = ptr rocksdb_backup_engine_t

  BackupEngineRef* = ref object
    cPtr: BackupEnginePtr
    path: string
    backupOpts: BackupEngineOptionsRef

proc openBackupEngine*(
    path: string,
    backupOpts = defaultBackupEngineOptions()): RocksDBResult[BackupEngineRef] =
  ## Create a new backup engine. The `path` parameter is the path of the backup
  ## directory. Note that the same directory should not be used for both backups
  ## and the database itself.

  var errors: cstring
  let backupEnginePtr = rocksdb_backup_engine_open(
    backupOpts.cPtr,
    path.cstring,
    cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  let engine = BackupEngineRef(
    cPtr: backupEnginePtr,
    path: path,
    backupOpts: backupOpts)
  ok(engine)

proc isClosed*(backupEngine: BackupEngineRef): bool {.inline.} =
  ## Returns `true` if the `BackupEngineRef` has been closed.
  backupEngine.cPtr.isNil()

proc createNewBackup*(
    backupEngine: BackupEngineRef,
    db: RocksDbRef): RocksDBResult[void] =
  ## Create a new backup of the database.
  doAssert not backupEngine.isClosed()
  doAssert not db.isClosed()

  var errors: cstring
  rocksdb_backup_engine_create_new_backup(
    backupEngine.cPtr,
    db.cPtr,
    cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  ok()

proc restoreDbFromLatestBackup*(
    backupEngine: BackupEngineRef,
    dbDir: string,
    walDir = dbDir,
    keepLogFiles = false): RocksDBResult[void] =
  ## Restore the database from the latest backup.
  doAssert not backupEngine.isClosed()

  let restoreOptions = rocksdb_restore_options_create()
  rocksdb_restore_options_set_keep_log_files(restoreOptions, keepLogFiles.cint)

  var errors: cstring
  rocksdb_backup_engine_restore_db_from_latest_backup(
    backupEngine.cPtr,
    dbDir.cstring,
    walDir.cstring,
    restoreOptions,
    cast[cstringArray](errors.addr))
  bailOnErrors(errors)

  rocksdb_restore_options_destroy(restoreOptions)

  ok()

proc close*(backupEngine: BackupEngineRef) =
  ## Close the `BackupEngineRef`.
  if not backupEngine.isClosed():
    rocksdb_backup_engine_close(backupEngine.cPtr)
    backupEngine.cPtr = nil
