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
  std/tables,
  ../columnfamily/cfhandle

export
  cfhandle

type
  ColFamilyTableRef* = ref object
    columnFamilies: TableRef[string, ColFamilyHandleRef]

proc newColFamilyTable*(
    names: openArray[string],
    handles: openArray[ColFamilyHandlePtr]): ColFamilyTableRef =
  doAssert names.len() == handles.len()

  let cfTable =  newTable[string, ColFamilyHandleRef]()
  for i, name in names:
    cfTable[name] = newColFamilyHandle(handles[i])

  ColFamilyTableRef(columnFamilies: cfTable)

proc isClosed*(table: ColFamilyTableRef): bool {.inline.} =
  table.columnFamilies.isNil()

proc get*(table: ColFamilyTableRef, name: string): ColFamilyHandleRef =
  table.columnFamilies.getOrDefault(name)

proc close*(table: ColFamilyTableRef) =
  if not table.isClosed():
    for _, v in table.columnFamilies.mpairs():
      v.close()
    table.columnFamilies = nil
