import pkg/chronos
import pkg/asynctest
import pkg/questionable/results
import pkg/codex/blocktype as bt
import pkg/codex/stores/cachestore

import ../helpers

import codex/slotbuilder/slotbuilder

asyncchecksuite "Slot builder":
  test "a":
    let builder = SlotBuilder()
    builder.aaa()

    check:
      1 == 1
