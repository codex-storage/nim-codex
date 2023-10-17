import pkg/upraises
import pkg/chronos
import pkg/chronos/futures
import pkg/chronicles
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ../blocktype
import ../merkletree
import ../utils

const DefaultTreeCacheCapacity* = 10    # Max number of trees stored in memory

type
  GetBlock = proc (cid: Cid): Future[?!Block] {.upraises: [], gcsafe, closure.}
  TreeReader* = ref object of RootObj
    getBlockFromStore*: GetBlock
    treeCache*: LruCache[Cid, MerkleTree]

proc getTree*(self: TreeReader, cid: Cid): Future[?!MerkleTree] {.async.} =
  if tree =? self.treeCache.getOption(cid):
    return success(tree)
  else:
    without treeBlk =? await self.getBlockFromStore(cid), err:
      return failure(err)

    without tree =? MerkleTree.decode(treeBlk.data), err:
      return failure("Error decoding a merkle tree with cid " & $cid & ". Nested error is: " & err.msg)
    self.treeCache[cid] = tree

    trace "Got merkle tree for cid", cid
    return success(tree)

proc getBlockCidAndProof*(self: TreeReader, treeCid: Cid, index: Natural): Future[?!(Cid, MerkleProof)] {.async.} =
  without tree =? await self.getTree(treeCid), err:
    return failure(err)

  without proof =? tree.getProof(index), err:
    return failure(err)

  without leaf =? tree.getLeaf(index), err:
    return failure(err)

  without leafCid =? Cid.init(treeCid.cidver, treeCid.mcodec, leaf).mapFailure, err:
    return failure(err)

  return success((leafCid, proof))

proc getBlockCid*(self: TreeReader, treeCid: Cid, index: Natural): Future[?!Cid] {.async.} =
  without tree =? await self.getTree(treeCid), err:
    return failure(err)

  without leaf =? tree.getLeaf(index), err:
    return failure(err)

  without leafCid =? Cid.init(treeCid.cidver, treeCid.mcodec, leaf).mapFailure, err:
    return failure(err)

  return success(leafCid)

proc getBlock*(self: TreeReader, treeCid: Cid, index: Natural): Future[?!Block] {.async.} =
  without leafCid =? await self.getBlockCid(treeCid, index), err:
    return failure(err)

  without blk =? await self.getBlockFromStore(leafCid), err:
    return failure(err)

  return success(blk)

proc getBlockAndProof*(self: TreeReader, treeCid: Cid, index: Natural): Future[?!(Block, MerkleProof)] {.async.} =
  without (leafCid, proof) =? await self.getBlockCidAndProof(treeCid, index), err:
    return failure(err)

  without blk =? await self.getBlockFromStore(leafCid), err:
    return failure(err)

  return success((blk, proof))

proc getBlocks*(self: TreeReader, treeCid: Cid, leavesCount: Natural): Future[?!AsyncIter[?!Block]] {.async.} =
  without tree =? await self.getTree(treeCid), err:
    return failure(err)

  let iter = Iter.fromSlice(0..<leavesCount)
    .map(proc (index: int): Future[?!Block] {.async.} =
      without leaf =? tree.getLeaf(index), err:
        return failure(err)

      without leafCid =? Cid.init(treeCid.cidver, treeCid.mcodec, leaf).mapFailure, err:
        return failure(err)

      without blk =? await self.getBlockFromStore(leafCid), err:
        return failure(err)

      return success(blk)
    )
  return success(iter)

proc new*(T: type TreeReader, treeCacheCap = DefaultTreeCacheCapacity): TreeReader =
  TreeReader(treeCache: newLruCache[Cid, MerkleTree](treeCacheCap))