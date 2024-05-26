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
  ../lib/librocksdb

type
  ColFamilyOptionsPtr* = ptr rocksdb_options_t

  ColFamilyOptionsRef* = ref object
    cPtr: ColFamilyOptionsPtr

proc newColFamilyOptions*(): ColFamilyOptionsRef =
  ColFamilyOptionsRef(cPtr: rocksdb_options_create())

proc isClosed*(cfOpts: ColFamilyOptionsRef): bool {.inline.} =
  cfOpts.cPtr.isNil()

proc cPtr*(cfOpts: ColFamilyOptionsRef): ColFamilyOptionsPtr =
  doAssert not cfOpts.isClosed()
  cfOpts.cPtr

proc setCreateMissingColumnFamilies*(cfOpts: ColFamilyOptionsRef, flag: bool) =
  doAssert not cfOpts.isClosed()
  rocksdb_options_set_create_missing_column_families(cfOpts.cPtr, flag.uint8)

proc defaultColFamilyOptions*(): ColFamilyOptionsRef =
  let opts = newColFamilyOptions()

  # rocksdb_options_set_compression(opts.cPtr, rocksdb_lz4_compression)
  # rocksdb_options_set_bottommost_compression(opts.cPtr, rocksdb_zstd_compression)

  # Enable creating column families if they do not exist
  opts.setCreateMissingColumnFamilies(true)
  return opts

# TODO: These procs below will not work unless using the latest version of rocksdb
# Currently, when installing librocksdb-dev on linux the RocksDb version used is 6.11.4
# Need to complete this task: https://github.com/status-im/nim-rocksdb/issues/10

# proc getCreateMissingColumnFamilies*(cfOpts: ColFamilyOptionsRef): bool =
#   doAssert not cfOpts.isClosed()
#   rocksdb_options_get_create_missing_column_families(cfOpts.cPtr).bool

proc close*(cfOpts: ColFamilyOptionsRef) =
  if not cfOpts.isClosed():
    rocksdb_options_destroy(cfOpts.cPtr)
    cfOpts.cPtr = nil
