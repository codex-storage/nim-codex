import ../rocksdb/lib/librocksdb, cpuinfo

const
  dbPath: cstring = "/tmp/rocksdb_simple_example"
  dbBackupPath: cstring = "/tmp/rocksdb_simple_example_backup"

proc main() =
  var
    db: ptr rocksdb_t
    be: ptr rocksdb_backup_engine_t
    options = rocksdb_options_create()
  # Optimize RocksDB. This is the easiest way to
  # get RocksDB to perform well
  let cpus = countProcessors()
  rocksdb_options_increase_parallelism(options, cpus.int32)
  # This requires snappy - disabled because rocksdb is not always compiled with
  # snappy support (for example Fedora 28, certain Ubuntu versions)
  # rocksdb_options_optimize_level_style_compaction(options, 0);
  # create the DB if it's not already present
  rocksdb_options_set_create_if_missing(options, 1);

  # open DB
  var err: cstring  # memory leak: example code does not free error string!
  db = rocksdb_open(options, dbPath, cast[cstringArray](err.addr))
  doAssert err.isNil, $err

  # open Backup Engine that we will use for backing up our database
  be = rocksdb_backup_engine_open(options, dbBackupPath, cast[cstringArray](err.addr))
  doAssert err.isNil, $err

  # Put key-value
  var writeOptions = rocksdb_writeoptions_create()
  let key = "key"
  let put_value = "value"
  rocksdb_put(db, writeOptions, key.cstring, key.len.csize_t, put_value.cstring,
      put_value.len.csize_t, cast[cstringArray](err.addr))
  doAssert err.isNil, $err

  # Get value
  var readOptions = rocksdb_readoptions_create()
  var len: csize_t
  let raw_value = rocksdb_get(db, readOptions, key.cstring, key.len.csize_t, addr len,
      cast[cstringArray](err.addr)) # Important: rocksdb_get is not null-terminated
  doAssert err.isNil, $err

  # Copy it to a regular Nim string (copyMem workaround because raw value is NOT null-terminated)
  var get_value = newString(len.int)
  copyMem(addr get_value[0], unsafeAddr raw_value[0], len.int * sizeof(char))

  doAssert get_value == put_value

  # create new backup in a directory specified by DBBackupPath
  rocksdb_backup_engine_create_new_backup(be, db, cast[cstringArray](err.addr))
  doAssert err.isNil, $err

  rocksdb_close(db)

  # If something is wrong, you might want to restore data from last backup
  var restoreOptions = rocksdb_restore_options_create()
  rocksdb_backup_engine_restore_db_from_latest_backup(be, dbPath, dbPath,
      restoreOptions, cast[cstringArray](err.addr))
  doAssert err.isNil, $err
  rocksdb_restore_options_destroy(restore_options)

  db = rocksdb_open(options, dbPath, cast[cstringArray](err.addr))
  doAssert err.isNil, $err

  # cleanup
  rocksdb_writeoptions_destroy(writeOptions)
  rocksdb_readoptions_destroy(readOptions)
  rocksdb_options_destroy(options)
  rocksdb_backup_engine_close(be)
  rocksdb_close(db)

main()
