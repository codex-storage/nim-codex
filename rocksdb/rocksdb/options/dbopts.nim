# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/cpuinfo,
  ../lib/librocksdb

type
  DbOptionsPtr* = ptr rocksdb_options_t

  DbOptionsRef* = ref object
    cPtr: DbOptionsPtr

proc newDbOptions*(): DbOptionsRef =
  DbOptionsRef(cPtr: rocksdb_options_create())

proc isClosed*(dbOpts: DbOptionsRef): bool {.inline.} =
  dbOpts.cPtr.isNil()

proc cPtr*(dbOpts: DbOptionsRef): DbOptionsPtr =
  doAssert not dbOpts.isClosed()
  dbOpts.cPtr

proc setIncreaseParallelism*(dbOpts: DbOptionsRef, totalThreads: int) =
  doAssert totalThreads > 0
  doAssert not dbOpts.isClosed()
  rocksdb_options_increase_parallelism(dbOpts.cPtr, totalThreads.cint)

proc setCreateIfMissing*(dbOpts: DbOptionsRef, flag: bool) =
  doAssert not dbOpts.isClosed()
  rocksdb_options_set_create_if_missing(dbOpts.cPtr, flag.uint8)

proc setMaxOpenFiles*(dbOpts: DbOptionsRef, maxOpenFiles: int) =
  doAssert maxOpenFiles >= -1
  doAssert not dbOpts.isClosed()
  rocksdb_options_set_max_open_files(dbOpts.cPtr, maxOpenFiles.cint)

proc setCreateMissingColumnFamilies*(dbOpts: DbOptionsRef, flag: bool) =
  doAssert not dbOpts.isClosed()
  rocksdb_options_set_create_missing_column_families(dbOpts.cPtr, flag.uint8)

proc defaultDbOptions*(): DbOptionsRef =
  let opts: DbOptionsRef = newDbOptions()

  # rocksdb_options_set_compression(opts.cPtr, rocksdb_lz4_compression)
  # rocksdb_options_set_bottommost_compression(opts.cPtr, rocksdb_zstd_compression)

  # Optimize RocksDB. This is the easiest way to get RocksDB to perform well:
  opts.setIncreaseParallelism(countProcessors())
  # This requires snappy - disabled because rocksdb is not always compiled with
  # snappy support (for example Fedora 28, certain Ubuntu versions)
  # rocksdb_options_optimize_level_style_compaction(options, 0);
  opts.setCreateIfMissing(true)
  # default set to keep all files open (-1), allow setting it to a specific
  # value, e.g. in case the application limit would be reached.
  opts.setMaxOpenFiles(-1)
  # Enable creating column families if they do not exist
  opts.setCreateMissingColumnFamilies(true)
  return opts

# TODO: These procs below will not work unless using the latest version of rocksdb
# Currently, when installing librocksdb-dev on linux the RocksDb version used is 6.11.4
# Need to complete this task: https://github.com/status-im/nim-rocksdb/issues/10

# proc getCreateIfMissing*(dbOpts: DbOptionsRef): bool =
#   doAssert not dbOpts.isClosed()
#   rocksdb_options_get_create_if_missing(dbOpts.cPtr).bool

# proc getMaxOpenFiles*(dbOpts: DbOptionsRef): int =
#   doAssert not dbOpts.isClosed()
#   rocksdb_options_get_max_open_files(dbOpts.cPtr).int

# proc getCreateMissingColumnFamilies*(dbOpts: DbOptionsRef): bool =
#   doAssert not dbOpts.isClosed()
#   rocksdb_options_get_create_missing_column_families(dbOpts.cPtr).bool

proc close*(dbOpts: DbOptionsRef) =
  if not dbOpts.isClosed():
    rocksdb_options_destroy(dbOpts.cPtr)
    dbOpts.cPtr = nil
