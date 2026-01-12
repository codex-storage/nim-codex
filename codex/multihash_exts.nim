import blscurve/bls_public_exports
import pkg/constantine/hashes

proc sha2_256hash_constantine(data: openArray[byte], output: var openArray[byte]) =
  # Using Constantine's SHA256 instead of mhash for optimal performance on 32-byte merkle node hashing
  # See: https://github.com/logos-storage/logos-storage-nim/issues/1162
  if len(output) > 0:
    let digest = hashes.sha256.hash(data)
    copyMem(addr output[0], addr digest[0], 32)

const Sha2256MultiHash* = MHash(
  mcodec: multiCodec("sha2-256"),
  size: sha256.sizeDigest,
  coder: sha2_256hash_constantine,
)
const HashExts = [
  # override sha2-256 hash function
  Sha2256MultiHash
]
