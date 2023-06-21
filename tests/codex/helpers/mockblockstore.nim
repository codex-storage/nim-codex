import pkg/chronos
import pkg/libp2p
import pkg/questionable/results
import pkg/codex/stores/blockstore

type
  MockBlockStore* = ref object of BlockStore
    numberOfGetCalls*: int
    getBlock*: Block

method getBlock*(self: MockBlockStore, cid: Cid): Future[?!Block] {.async.} =
  inc self.numberOfGetCalls
  return success(self.getBlock)
