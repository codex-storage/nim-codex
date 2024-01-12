import std/math
import std/sequtils

import pkg/libp2p
import pkg/chronos
import pkg/questionable/results
import pkg/poseidon2

import ../merkletree
import ../stores
import ../manifest
import ../utils
import ../utils/poseidon2digest

type ProofPadding* = object of RootObj
  blockEmptyDigest*: Poseidon2Hash
  blockPadBytes*: seq[byte]
  slotsPadLeafs*: seq[Poseidon2Hash]
  rootsPadLeafs*: seq[Poseidon2Hash]

const
  DefaultEmptyBlock* = newSeq[byte](DefaultBlockSize.int)

func nextPowerOfTwoPad*(a: int): int =
  ## Returns the difference between the original
  ## value and the next power of two.
  ##

  nextPowerOfTwo(a) - a

proc new*(
  T: type ProofPadding,
  manifest: Manifest,
  cellSize: NBytes): ?!ProofPadding =

  if not manifest.protected:
    return failure("Protected manifest is required.")

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    return failure("Number of blocks must be divisable by number of slots.")

  let cSize = cellSize.int

  if (manifest.blockSize.int mod cSize) != 0:
    return failure("Block size must be divisable by cell size.")

  let
    numBlockCells = manifest.blockSize.int div cSize
    numSlotLeafs = (manifest.blocksCount div manifest.numSlots)
    blockPadBytes = newSeq[byte](numBlockCells.nextPowerOfTwoPad * cSize)
    slotsPadLeafs = newSeqWith(numSlotLeafs.nextPowerOfTwoPad, Poseidon2Zero)
    rootsPadLeafs = newSeqWith(manifest.numSlots.nextPowerOfTwoPad, Poseidon2Zero)
    blockEmptyDigest = ? Poseidon2Tree.digest(DefaultEmptyBlock & blockPadBytes, cSize)

  success(ProofPadding(
    blockEmptyDigest: blockEmptyDigest,
    blockPadBytes: blockPadBytes,
    slotsPadLeafs: slotsPadLeafs,
    rootsPadLeafs: rootsPadLeafs
  ))
