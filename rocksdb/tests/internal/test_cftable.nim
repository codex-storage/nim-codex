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
  ../../rocksdb/lib/librocksdb,
  ../../rocksdb/columnfamily/cfhandle,
  ../../rocksdb/internal/cftable

suite "ColFamilyTableRef Tests":

  const TEST_CF_NAME = "test"

  setup:
    let
      dbPath = mkdtemp() / "data"
      dbOpts = rocksdb_options_create()
      cfOpts = rocksdb_options_create()

    var
      errors: cstring

    rocksdb_options_set_create_if_missing(dbOpts, 1);

    let db = rocksdb_open(dbOpts, dbPath.cstring, cast[cstringArray](errors.addr))
    doAssert errors.isNil()
    doAssert not db.isNil()

    let cfHandlePtr = rocksdb_create_column_family(
        db,
        cfOpts,
        TEST_CF_NAME.cstring,
        cast[cstringArray](errors.addr))
    doAssert errors.isNil()
    doAssert not cfHandlePtr.isNil()

  teardown:
    rocksdb_close(db)
    removeDir($dbPath)


  test "Test newColFamilyTable":
    var cfTable = newColFamilyTable(
          @[TEST_CF_NAME, TEST_CF_NAME],
          @[cfHandlePtr, cfHandlePtr])

    check cfTable.get(TEST_CF_NAME).cPtr() == cfHandlePtr
    check not cfTable.isClosed()

    # doesn't exist
    check cfTable.get("other").isNil()
    check not cfTable.isClosed()

    cfTable.close()

  test "Test close":
    var cfTable = newColFamilyTable(@[TEST_CF_NAME], @[cfHandlePtr])

    let cfHandle = cfTable.get(TEST_CF_NAME)

    check not cfHandle.isClosed()
    check not cfTable.isClosed()
    cfTable.close()
    check cfHandle.isClosed()
    check cfTable.isClosed()
    cfTable.close()
    check cfTable.isClosed()
