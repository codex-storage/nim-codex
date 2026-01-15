## Logos Storage
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[bitops, atomics, sequtils]
import stew/assign2

import pkg/questionable/results
import pkg/taskpools
import pkg/chronos
import pkg/chronos/threadsync

import ../errors
import ../utils/sharedbuf

export sharedbuf

template nodeData(
    data: openArray[byte], offsets: openArray[int], nodeSize, i, j: int
): openArray[byte] =
  ## Bytes of the j'th entry of the i'th level in the tree, starting with the
  ## leaves (at level 0).
  let start = (offsets[i] + j) * nodeSize
  data.toOpenArray(start, start + nodeSize - 1)

type
  # TODO hash functions don't fail - removing the ?! from this function would
  #      significantly simplify the flow below
  CompressFn*[H, K] = proc(x, y: H, key: K): ?!H {.noSideEffect, raises: [].}

  CompressData[H, K] = object
    fn: CompressFn[H, K]
    nodeSize: int
    zero: H

  MerkleTreeObj*[H, K] = object of RootObj
    store*: seq[byte]
      ## Flattened merkle tree where hashes are assumed to be trivial bytes and
      ## uniform in size.
      ##
      ## Each layer of the tree is stored serially starting with the leaves and
      ## ending with the root.
      ##
      ## Beacuse the tree might not be balanced, `layerOffsets` contains the
      ## index of the starting point of each level, for easy lookup.
    layerOffsets*: seq[int]
      ## Starting point of each level in the tree, starting from the leaves -
      ## multiplied by the entry size, this is the offset in the payload where
      ## the entries of that level start
      ##
      ## For example, a tree with 4 leaves will have [0, 4, 6] stored here.
      ##
      ## See nodesPerLevel function, from whic this sequence is derived
    compress*: CompressData[H, K]

  MerkleTree*[H, K] = ref MerkleTreeObj[H, K]

  MerkleProof*[H, K] = ref object of RootObj
    index*: int # linear index of the leaf, starting from 0
    path*: seq[H] # order: from the bottom to the top
    nleaves*: int # number of leaves in the tree (=size of input)
    compress*: CompressFn[H, K] # compress function
    zero*: H # zero value

func levels*[H, K](self: MerkleTree[H, K]): int =
  return self.layerOffsets.len

func depth*[H, K](self: MerkleTree[H, K]): int =
  return self.levels() - 1

func nodesInLayer(offsets: openArray[int], layer: int): int =
  if layer == offsets.high:
    1
  else:
    offsets[layer + 1] - offsets[layer]

func nodesInLayer(self: MerkleTree | MerkleTreeObj, layer: int): int =
  self.layerOffsets.nodesInLayer(layer)

func leavesCount*[H, K](self: MerkleTree[H, K]): int =
  return self.nodesInLayer(0)

func nodesPerLevel(nleaves: int): seq[int] =
  ## Given a number of leaves, return a seq with the number of nodes at each
  ## layer of the tree (from the bottom/leaves to the root)
  ##
  ## Ie For a tree of 4 leaves, return `[4, 2, 1]`
  if nleaves <= 0:
    return @[]
  elif nleaves == 1:
    return @[1, 1] # leaf and root

  var nodes: seq[int] = @[]
  var m = nleaves
  while true:
    nodes.add(m)
    if m == 1:
      break
    # Next layer size is ceil(m/2)
    m = (m + 1) shr 1

  nodes

func layerOffsets(nleaves: int): seq[int] =
  ## Given a number of leaves, return a seq of the starting offsets of each
  ## layer in the node store that results from flattening the binary tree
  ##
  ## Ie For a tree of 4 leaves, return `[0, 4, 6]`
  let nodes = nodesPerLevel(nleaves)
  var tot = 0
  let offsets = nodes.mapIt:
    let cur = tot
    tot += it
    cur
  offsets

template nodeData(self: MerkleTreeObj, i, j: int): openArray[byte] =
  ## Bytes of the j'th node of the i'th level in the tree, starting with the
  ## leaves (at level 0).
  self.store.nodeData(self.layerOffsets, self.compress.nodeSize, i, j)

func layer*[H, K](
    self: MerkleTree[H, K], layer: int
): seq[H] {.deprecated: "Expensive".} =
  var nodes = newSeq[H](self.nodesInLayer(layer))
  for i, h in nodes.mpairs:
    assign(h, self[].nodeData(layer, i))
  return nodes

func leaves*[H, K](self: MerkleTree[H, K]): seq[H] {.deprecated: "Expensive".} =
  self.layer(0)

iterator layers*[H, K](self: MerkleTree[H, K]): seq[H] {.deprecated: "Expensive".} =
  for i in 0 ..< self.layerOffsets.len:
    yield self.layer(i)

proc layers*[H, K](self: MerkleTree[H, K]): seq[seq[H]] {.deprecated: "Expensive".} =
  for l in self.layers():
    result.add l

iterator nodes*[H, K](self: MerkleTree[H, K]): H =
  ## Iterate over the nodes of each layer starting with the leaves
  var node: H
  for i in 0 ..< self.layerOffsets.len:
    let nodesInLayer = self.nodesInLayer(i)
    for j in 0 ..< nodesInLayer:
      assign(node, self[].nodeData(i, j))
      yield node

func root*[H, K](self: MerkleTree[H, K]): ?!H =
  mixin assign
  if self.layerOffsets.len == 0:
    return failure "invalid tree"

  var h: H
  assign(h, self[].nodeData(self.layerOffsets.high(), 0))
  return success h

func getProof*[H, K](
    self: MerkleTree[H, K], index: int, proof: MerkleProof[H, K]
): ?!void =
  let depth = self.depth
  let nleaves = self.leavesCount

  if not (index >= 0 and index < nleaves):
    return failure "index out of bounds"

  var path: seq[H] = newSeq[H](depth)
  var k = index
  var m = nleaves
  for i in 0 ..< depth:
    let j = k xor 1

    if (j < m):
      assign(path[i], self[].nodeData(i, j))
    else:
      path[i] = self.compress.zero

    k = k shr 1
    m = (m + 1) shr 1

  proof.index = index
  proof.path = path
  proof.nleaves = nleaves
  proof.compress = self.compress.fn

  success()

func getProof*[H, K](self: MerkleTree[H, K], index: int): ?!MerkleProof[H, K] =
  var proof = MerkleProof[H, K]()

  ?self.getProof(index, proof)

  success proof

func reconstructRoot*[H, K](proof: MerkleProof[H, K], leaf: H): ?!H =
  var
    m = proof.nleaves
    j = proof.index
    h = leaf
    bottomFlag = K.KeyBottomLayer

  for p in proof.path:
    let oddIndex: bool = (bitand(j, 1) != 0)
    if oddIndex:
      # the index of the child is odd, so the node itself can't be odd (a bit counterintuitive, yeah :)
      h = ?proof.compress(p, h, bottomFlag)
    else:
      if j == m - 1:
        # single child => odd node
        h = ?proof.compress(h, p, K(bottomFlag.ord + 2))
      else:
        # even node
        h = ?proof.compress(h, p, bottomFlag)
    bottomFlag = K.KeyNone
    j = j shr 1
    m = (m + 1) shr 1

  return success h

func verify*[H, K](proof: MerkleProof[H, K], leaf: H, root: H): ?!bool =
  success bool(root == ?proof.reconstructRoot(leaf))

func fromNodes*[H, K](
    self: MerkleTree[H, K],
    compressor: CompressFn,
    zero: H,
    nodes: openArray[H],
    nleaves: int,
): ?!void =
  mixin assign

  if nodes.len < 2: # At least leaf and root
    return failure "Not enough nodes"

  if nleaves == 0:
    return failure "No leaves"

  self.compress = CompressData[H, K](fn: compressor, nodeSize: nodes[0].len, zero: zero)
  self.layerOffsets = layerOffsets(nleaves)

  if self.layerOffsets[^1] + 1 != nodes.len:
    return failure "bad node count"

  self.store = newSeqUninit[byte](nodes.len * self.compress.nodeSize)

  for i in 0 ..< nodes.len:
    assign(
      self[].store.toOpenArray(
        i * self.compress.nodeSize, (i + 1) * self.compress.nodeSize - 1
      ),
      nodes[i],
    )

  success()

func merkleTreeWorker[H, K](
    store: var openArray[byte],
    offsets: openArray[int],
    compress: CompressData[H, K],
    layer: int,
    isBottomLayer: static bool,
): ?!void =
  ## Worker used to compute the merkle tree from the leaves that are assumed to
  ## already be stored at the beginning of the `store`, as done by `prepare`.

  # Throughout, we use `assign` to convert from H to bytes and back, assuming
  # this assignment can be done somewhat efficiently (ie memcpy) - because
  # the code must work with multihash where len(H) is can differ, we cannot
  # simply use a fixed-size array here.
  mixin assign

  template nodeData(i, j: int): openArray[byte] =
    # Pick out the bytes of node j in layer i
    store.nodeData(offsets, compress.nodeSize, i, j)

  let m = offsets.nodesInLayer(layer)

  when not isBottomLayer:
    if m == 1:
      return success()

  let halfn: int = m div 2
  let n: int = 2 * halfn
  let isOdd: bool = (n != m)

  # Because the compression function we work with works with H and not bytes,
  # we need to extract H from the raw data - a little abstraction tax that
  # ensures that properties like alignment of H are respected.
  var a, b, tmp: H

  for i in 0 ..< halfn:
    const key = when isBottomLayer: K.KeyBottomLayer else: K.KeyNone

    assign(a, nodeData(layer, i * 2))
    assign(b, nodeData(layer, i * 2 + 1))

    tmp = ?compress.fn(a, b, key = key)

    assign(nodeData(layer + 1, i), tmp)

  if isOdd:
    const key = when isBottomLayer: K.KeyOddAndBottomLayer else: K.KeyOdd

    assign(a, nodeData(layer, n))

    tmp = ?compress.fn(a, compress.zero, key = key)

    assign(nodeData(layer + 1, halfn), tmp)

  merkleTreeWorker(store, offsets, compress, layer + 1, false)

proc merkleTreeWorker[H, K](
    store: SharedBuf[byte],
    offsets: SharedBuf[int],
    compress: ptr CompressData[H, K],
    signal: ThreadSignalPtr,
): bool =
  defer:
    discard signal.fireSync()

  let res = merkleTreeWorker(
    store.toOpenArray(), offsets.toOpenArray(), compress[], 0, isBottomLayer = true
  )

  return res.isOk()

func prepare*[H, K](
    self: MerkleTree[H, K], compressor: CompressFn, zero: H, leaves: openArray[H]
): ?!void =
  ## Prepare the instance for computing the merkle tree of the given leaves using
  ## the given compression function. After preparation, `compute` should be
  ## called to perform the actual computation. `leaves` will be copied into the
  ## tree so they can be freed after the call.

  if leaves.len == 0:
    return failure "No leaves"

  self.compress =
    CompressData[H, K](fn: compressor, nodeSize: leaves[0].len, zero: zero)
  self.layerOffsets = layerOffsets(leaves.len)

  self.store = newSeqUninit[byte]((self.layerOffsets[^1] + 1) * self.compress.nodeSize)

  for j in 0 ..< leaves.len:
    assign(self[].nodeData(0, j), leaves[j])

  return success()

proc compute*[H, K](self: MerkleTree[H, K]): ?!void =
  merkleTreeWorker(
    self.store, self.layerOffsets, self.compress, 0, isBottomLayer = true
  )

proc compute*[H, K](
    self: MerkleTree[H, K], tp: Taskpool
): Future[?!void] {.async: (raises: []).} =
  if tp.numThreads == 1:
    # With a single thread, there's no point creating a separate task
    return self.compute()

  # TODO this signal would benefit from reuse across computations
  without signal =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    signal.close().expect("closing once works")

  let res = tp.spawn merkleTreeWorker(
    SharedBuf.view(self.store),
    SharedBuf.view(self.layerOffsets),
    addr self.compress,
    signal,
  )

  # To support cancellation, we'd have to ensure the task we posted to taskpools
  # exits early - since we're not doing that, block cancellation attempts
  try:
    await noCancel signal.wait()
  except AsyncError as exc:
    # Since we initialized the signal, the OS or chronos is misbehaving. In any
    # case, it would mean the task is still running which would cause a memory
    # a memory violation if we let it run - panic instead
    raiseAssert "Could not wait for signal, was it initialized? " & exc.msg

  if not res.sync():
    return failure("merkle tree task failed")

  return success()
