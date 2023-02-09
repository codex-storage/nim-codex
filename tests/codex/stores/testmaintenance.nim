import pkg/questionable

import pkg/chronos
import pkg/asynctest

suite "BlockMaintainer":

#   var
#     repoDs: Datastore
#     metaDs: Datastore

#   setup:
#     repoDs = SQLiteDatastore.new(Memory).tryGet()
#     metaDs = SQLiteDatastore.new(Memory).tryGet()

#   teardown:
#     (await repoDs.close()).tryGet
#     (await metaDs.close()).tryGet

  test "Start should begin checking each BlockStoreChecker":
    let bm = BlockMaintainer.new()
    bm.start(blockStore1)
    
# start two loops, see how to yield
