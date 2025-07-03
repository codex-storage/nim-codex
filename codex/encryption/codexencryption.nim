## Nim-Codex
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import bearssl/[blockx, hash]
import stew/[byteutils, endians2]

import ../rng
import ./bearsslhash

{.push raises: [].}

const
  MasterKeySize = 32 # 256 bits
  KeySize = 24 # 192 bits for AES-192
  IvSize = 16 # 128 bits
  KeyDerivationIdentifier = "aes192_block_key".toBytes
  IvDerivationIdentifier = "aes192_block_iv".toBytes

type CodexEncryption* = ref object
  masterKey: seq[byte]

proc newCodexEncryption*(): CodexEncryption =
  let masterKey = newSeqWith(MasterKeySize, Rng.instance.rand(uint8.high).byte)
  CodexEncryption(masterKey: masterKey)

proc newCodexEncryption*(masterKey: seq[byte]): CodexEncryption =
  CodexEncryption(masterKey: masterKey)

proc getKeyHexEncoded*(self: CodexEncryption): string =
  self.masterKey.toHex()

proc deriveKeyForBlockIndex(self: CodexEncryption, blockIndex: uint32): seq[byte] =
  let blockIndexArray = toBytes(blockIndex, bigEndian)
  bearSslHash(
    addr sha256Vtable, self.masterKey & KeyDerivationIdentifier & blockIndexArray.toSeq
  )[0 ..< KeySize]

proc deriveIvForBlockIndex(self: CodexEncryption, blockIndex: uint32): seq[byte] =
  let blockIndexArray = toBytes(blockIndex, bigEndian)
  bearSslHash(
    addr sha256Vtable, self.masterKey & IvDerivationIdentifier & blockIndexArray.toSeq
  )[0 ..< IvSize]

proc encryptBlock*(
    self: CodexEncryption, blockData: seq[byte], blockIndex: uint32
): seq[byte] =
  let key = self.deriveKeyForBlockIndex(blockIndex)
  let iv = self.deriveIvForBlockIndex(blockIndex)
  result = blockData

  var encCtx: AesBigCbcencKeys
  aesBigCbcencInit(encCtx, addr key[0], key.len.uint)
  aesBigCbcencRun(encCtx, addr iv[0], addr result[0], iv.len.uint)

proc decryptBlock*(
    self: CodexEncryption, encryptedBlockData: seq[byte], blockIndex: uint32
): seq[byte] =
  let key = self.deriveKeyForBlockIndex(blockIndex)
  let iv = self.deriveIvForBlockIndex(blockIndex)
  result = encryptedBlockData

  var decCtx: AesBigCbcdecKeys
  aesBigCbcdecInit(decCtx, addr key[0], key.len.uint)
  aesBigCbcdecRun(decCtx, addr iv[0], addr result[0], iv.len.uint)
