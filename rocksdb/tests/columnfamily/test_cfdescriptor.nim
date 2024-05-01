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
  ../../rocksdb/internal/utils,
  ../../rocksdb/columnfamily/cfdescriptor

suite "ColFamilyDescriptor Tests":

  const TEST_CF_NAME = "test"

  test "Test initColFamilyDescriptor":
    var descriptor = initColFamilyDescriptor(TEST_CF_NAME)

    check:
      descriptor.name() == TEST_CF_NAME
      not descriptor.options().isNil()
      not descriptor.isDefault()

    descriptor.close()

  test "Test initColFamilyDescriptor with options":
    var descriptor = initColFamilyDescriptor(TEST_CF_NAME, defaultColFamilyOptions())

    check:
      descriptor.name() == TEST_CF_NAME
      not descriptor.options().isNil()
      not descriptor.isDefault()

    descriptor.close()

  test "Test defaultColFamilyDescriptor":
    var descriptor = defaultColFamilyDescriptor()

    check:
      descriptor.name() == DEFAULT_COLUMN_FAMILY_NAME
      not descriptor.options().isNil()
      descriptor.isDefault()

    descriptor.close()

  test "Test close":
    var descriptor = defaultColFamilyDescriptor()

    check not descriptor.isClosed()
    descriptor.close()
    check descriptor.isClosed()
    descriptor.close()
    check descriptor.isClosed()

