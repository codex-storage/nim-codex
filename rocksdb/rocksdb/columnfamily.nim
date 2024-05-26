# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## `ColFamilyReadOnly` and `ColFamilyReadWrite` types both hold a reference to a
## `RocksDbReadOnlyRef` or `RocksDbReadWriteRef` respectively. They are convenience
## types which enable writing to a specific column family without having to specify the
## column family in each call.
##
## These column family types do not own the underlying `RocksDbRef` and therefore
## to close the database, simply call `columnFamily.db.close()` which will close
## the underlying `RocksDbRef`. Note that doing so will also impact any other column
## families that hold a reference to the same `RocksDbRef`.

{.push raises: [].}

import
  ./rocksdb

export rocksdb

type
  ColFamilyReadOnly* = object
    db: RocksDbReadOnlyRef
    name: string

  ColFamilyReadWrite* = object
    db: RocksDbReadWriteRef
    name: string

proc withColFamily*(
    db: RocksDbReadOnlyRef,
    name: string): RocksDBResult[ColFamilyReadOnly] =
  ## Creates a new `ColFamilyReadOnly` from the given `RocksDbReadOnlyRef` and
  ## column family name.

  # validate that the column family exists
  discard db.keyExists(@[0.byte], name).valueOr:
    return err(error)

  ok(ColFamilyReadOnly(db: db, name: name))

proc withColFamily*(
    db: RocksDbReadWriteRef,
    name: string): RocksDBResult[ColFamilyReadWrite] =
  ## Create a new `ColFamilyReadWrite` from the given `RocksDbReadWriteRef` and
  ## column family name.

  # validate that the column family exists
  discard db.keyExists(@[0.byte], name).valueOr:
    return err(error)

  ok(ColFamilyReadWrite(db: db, name: name))

proc db*(cf: ColFamilyReadOnly | ColFamilyReadWrite): auto {.inline.} =
  ## Returns the underlying `RocksDbReadOnlyRef` or `RocksDbReadWriteRef`.
  cf.db

proc name*(cf: ColFamilyReadOnly | ColFamilyReadWrite): string {.inline.} =
  ## Returns the name of the column family.
  cf.name

proc get*(
    cf: ColFamilyReadOnly | ColFamilyReadWrite,
    key: openArray[byte],
    onData: DataProc): RocksDBResult[bool] {.inline.} =
  ## Gets the value of the given key from the column family using the `onData`
  ## callback.
  cf.db.get(key, onData, cf.name)

proc get*(
    cf: ColFamilyReadOnly | ColFamilyReadWrite,
    key: openArray[byte]): RocksDBResult[seq[byte]] {.inline.} =
  ## Gets the value of the given key from the column family.
  cf.db.get(key, cf.name)

proc put*(
    cf: ColFamilyReadWrite,
    key, val: openArray[byte]): RocksDBResult[void] {.inline.} =
  ## Puts a value for the given key into the column family.
  cf.db.put(key, val, cf.name)

proc keyExists*(
    cf: ColFamilyReadOnly | ColFamilyReadWrite,
    key: openArray[byte]): RocksDBResult[bool] {.inline.} =
  ## Checks if the given key exists in the column family.
  cf.db.keyExists(key, cf.name)

proc delete*(
    cf: ColFamilyReadWrite,
    key: openArray[byte]): RocksDBResult[void] {.inline.} =
  ## Deletes the given key from the column family.
  cf.db.delete(key, cf.name)

proc openIterator*(
    cf: ColFamilyReadOnly | ColFamilyReadWrite): RocksDBResult[RocksIteratorRef] {.inline.} =
  ## Opens an `RocksIteratorRef` for the given column family.
  cf.db.openIterator(cf.name)

proc openWriteBatch*(cf: ColFamilyReadWrite): WriteBatchRef {.inline.} =
  ## Opens a `WriteBatchRef` for the given column family.
  cf.db.openWriteBatch(cf.name)

proc write*(
    cf: ColFamilyReadWrite,
    updates: WriteBatchRef): RocksDBResult[void] {.inline.} =
  ## Writes the updates in the `WriteBatchRef` to the column family.
  cf.db.write(updates)
