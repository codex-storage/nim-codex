## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[os, tables]

import pkg/libp2p
import pkg/libp2p/crypto/crypto
import pkg/libp2p/protocols/mix
import pkg/libp2p/protocols/mix/[curve25519, mix_node]
import pkg/questionable/results
import pkg/stew/byteutils

import ../errors

const MixIdentityFileSize = 2 * FieldElementSize

proc pickMixCompatibleMultiAddr*(addrs: openArray[MultiAddress]): Opt[MultiAddress] =
  ## Mix only supports /ip4/*/tcp/* or /ip4/*/udp/*/quic-v1 multiaddrs.
  for ma in addrs:
    if TCP_IP.match(ma) or QUIC_V1_IP.match(ma):
      return Opt.some(ma)
  Opt.none(MultiAddress)

proc loadOrGenerateMixKeys*(
    path: string
): ?!tuple[mixPub: FieldElement, mixPriv: FieldElement] =
  if fileExists(path):
    let raw =
      try:
        readFile(path)
      except IOError as exc:
        return failure("Failed to read mix-identity from " & path & ": " & exc.msg)

    if raw.len != MixIdentityFileSize:
      return failure(
        "Invalid mix-identity file size at " & path & " (expected " &
          $MixIdentityFileSize & ", got " & $raw.len & ")"
      )

    let
      pub = bytesToFieldElement(raw.toOpenArrayByte(0, FieldElementSize - 1)).valueOr:
        return failure("Bad mix pub key in " & path & ": " & error)
      priv = bytesToFieldElement(
        raw.toOpenArrayByte(FieldElementSize, 2 * FieldElementSize - 1)
      ).valueOr:
        return failure("Bad mix priv key in " & path & ": " & error)
    return success((mixPub: pub, mixPriv: priv))

  let (priv, pub) = generateKeyPair().valueOr:
    return failure("Failed to generate Mix keypair: " & error)

  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    try:
      createDir(dir)
    except OSError as exc:
      return failure("Failed to create directory " & dir & ": " & exc.msg)
    except IOError as exc:
      return failure("Failed to create directory " & dir & ": " & exc.msg)

  let blob = fieldElementToBytes(pub) & fieldElementToBytes(priv)

  try:
    writeFile(path, string.fromBytes(blob))
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except IOError as exc:
    return failure("Failed to write mix-identity to " & path & ": " & exc.msg)
  except OSError as exc:
    return failure("Failed to set permissions on " & path & ": " & exc.msg)

  success((mixPub: pub, mixPriv: priv))

proc buildMixNodeInfo*(
    mixPub, mixPriv: FieldElement,
    peerId: PeerId,
    multiAddr: MultiAddress,
    libp2pPriv: PrivateKey,
): ?!MixNodeInfo =
  if libp2pPriv.scheme != Secp256k1:
    return failure("Mix requires a Secp256k1 libp2p key; got " & $libp2pPriv.scheme)

  let libp2pPub = libp2pPriv.getPublicKey().valueOr:
    return failure("Failed to derive libp2p pub key: " & $error)

  if libp2pPub.scheme != Secp256k1:
    return failure("Unexpected libp2p pub key scheme: " & $libp2pPub.scheme)

  success initMixNodeInfo(
    peerId = peerId,
    multiAddr = multiAddr,
    mixPubKey = mixPub,
    mixPrivKey = mixPriv,
    libp2pPubKey = libp2pPub.skkey,
    libp2pPrivKey = libp2pPriv.skkey,
  )

proc loadRelayPubInfoTable*(mixPoolDir: string): ?!Table[PeerId, MixPubInfo] =
  let pubInfoDir = mixPoolDir / "pubInfo"
  if not dirExists(pubInfoDir):
    return failure("Relay pubInfo directory does not exist: " & pubInfoDir)

  var
    t = initTable[PeerId, MixPubInfo]()
    i = 0
  while true:
    let entry =
      try:
        MixPubInfo.readFromFile(i, pubInfoDir)
      except IOError as exc:
        return failure("I/O error reading pubInfo at index " & $i & ": " & exc.msg)
      except OSError as exc:
        return failure("OS error reading pubInfo at index " & $i & ": " & exc.msg)
    if entry.isErr:
      break
    let info = entry.get()
    t[info.peerId] = info
    inc i

  if t.len == 0:
    return failure("No relay entries found in " & pubInfoDir)

  success t

{.pop.}
