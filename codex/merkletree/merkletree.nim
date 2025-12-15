## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[bitops, atomics]
import stew/assign2

import pkg/questionable/results
import pkg/taskpools
import pkg/chronos/threadsync

import ../errors
import ../utils/sharedbuf

export sharedbuf

type
  CompressFn*[H, K] = proc(x, y: H, key: K): ?!H {.noSideEffect, raises: [].}

  MerkleTreeObj*[H, K] = object of RootObj
    layers*: seq[seq[H]]
    compress*: CompressFn[H, K]
    zero*: H

  MerkleTree*[H, K] = ref MerkleTreeObj[H, K]

  MerkleProof*[H, K] = ref object of RootObj
    index*: int # linear index of the leaf, starting from 0
    path*: seq[H] # order: from the bottom to the top
    nleaves*: int # number of leaves in the tree (=size of input)
    compress*: CompressFn[H, K] # compress function
    zero*: H # zero value

  MerkleTask*[H, K] = object
    tree*: ptr MerkleTreeObj[H, K]
    leaves*: SharedBuf[H]
    signal*: ThreadSignalPtr
    layers*: SharedBuf[byte]
    success*: Atomic[bool]

func depth*[H, K](self: MerkleTree[H, K]): int =
  return self.layers.len - 1

func leavesCount*[H, K](self: MerkleTree[H, K]): int =
  return self.layers[0].len

func levels*[H, K](self: MerkleTree[H, K]): int =
  return self.layers.len

func nodesPerLevel*(nleaves: int): seq[int] =
  ## Given a number of leaves, the number of nodes at each depth (from the
  ## bottom/leaves to the root)
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

func leaves*[H, K](self: MerkleTree[H, K]): seq[H] =
  return self.layers[0]

iterator layers*[H, K](self: MerkleTree[H, K]): seq[H] =
  for layer in self.layers:
    yield layer

iterator nodes*[H, K](self: MerkleTree[H, K]): H =
  for layer in self.layers:
    for node in layer:
      yield node

func root*[H, K](self: MerkleTree[H, K]): ?!H =
  let last = self.layers[^1]
  if last.len != 1:
    return failure "invalid tree"

  return success last[0]

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
    path[i] =
      if (j < m):
        self.layers[i][j]
      else:
        self.zero
    k = k shr 1
    m = (m + 1) shr 1

  proof.index = index
  proof.path = path
  proof.nleaves = nleaves
  proof.compress = self.compress

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

func merkleTreeWorker*[H, K](
    self: MerkleTreeObj[H, K], xs: openArray[H], isBottomLayer: static bool
): ?!seq[seq[H]] =
  let a = low(xs)
  let b = high(xs)
  let m = b - a + 1

  when not isBottomLayer:
    if m == 1:
      return success @[@xs]

  let halfn: int = m div 2
  let n: int = 2 * halfn
  let isOdd: bool = (n != m)

  var ys: seq[H]
  if not isOdd:
    ys = newSeq[H](halfn)
  else:
    ys = newSeq[H](halfn + 1)

  for i in 0 ..< halfn:
    const key = when isBottomLayer: K.KeyBottomLayer else: K.KeyNone
    ys[i] = ?self.compress(xs[a + 2 * i], xs[a + 2 * i + 1], key = key)
  if isOdd:
    const key = when isBottomLayer: K.KeyOddAndBottomLayer else: K.KeyOdd
    ys[halfn] = ?self.compress(xs[n], self.zero, key = key)

  success @[@xs] & ?self.merkleTreeWorker(ys, isBottomLayer = false)

proc pack*[H](tgt: SharedBuf[byte], v: seq[seq[H]]) =
  # Pack the given nested sequences into a flat buffer
  var pos = 0
  for layer in v:
    for h in layer:
      assign(tgt.toOpenArray(pos, pos + h.len - 1), h)
      pos += h.len

proc unpack*[H](src: SharedBuf[byte], nleaves, digestSize: int): seq[seq[H]] =
  # Given a flat buffer and the number of leaves, unpack the merkle tree from
  # its flat storage
  var
    nodesPerLevel = nodesPerLevel(nleaves)
    res = newSeq[seq[H]](nodesPerLevel.len)
    pos = 0
  for i, layer in res.mpairs:
    layer = newSeq[H](nodesPerLevel[i])
    for j, h in layer.mpairs:
      assign(h, src.toOpenArray(pos, pos + digestSize - 1))
      pos += digestSize
  res

proc merkleTreeWorker*[H, K](task: ptr MerkleTask[H, K]) {.gcsafe.} =
  defer:
    discard task[].signal.fireSync()

  let res = merkleTreeWorker(
    task[].tree[], task[].leaves.toOpenArray(), isBottomLayer = true
  ).valueOr:
    task[].success.store(false)
    return

  task.layers.pack(res)

  task[].success.store(true)
