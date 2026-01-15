import blscurve/bls_public_exports
import pkg/constantine/hashes
import poseidon2

proc sha2_256hash_constantine(data: openArray[byte], output: var openArray[byte]) =
  # Using Constantine's SHA256 instead of mhash for optimal performance on 32-byte merkle node hashing
  # See: https://github.com/logos-storage/logos-storage-nim/issues/1162
  if len(output) > 0:
    let digest = hashes.sha256.hash(data)
    copyMem(addr output[0], addr digest[0], 32)

proc poseidon2_sponge_rate2(data: openArray[byte], output: var openArray[byte]) =
  if len(output) > 0:
    var digest = poseidon2.Sponge.digest(data).toBytes()
    copyMem(addr output[0], addr digest[0], uint(len(output)))

proc poseidon2_merkle_2kb_sponge(data: openArray[byte], output: var openArray[byte]) =
  if len(output) > 0:
    var digest = poseidon2.SpongeMerkle.digest(data, 2048).toBytes()
    copyMem(addr output[0], addr digest[0], uint(len(output)))

const Sha2256MultiHash* = MHash(
  mcodec: multiCodec("sha2-256"),
  size: sha256.sizeDigest,
  coder: sha2_256hash_constantine,
)
const HashExts = [
  # override sha2-256 hash function
  Sha2256MultiHash,
  MHash(
    mcodec: multiCodec("poseidon2-alt_bn_128-sponge-r2"),
    size: 32,
    coder: poseidon2_sponge_rate2,
  ),
  MHash(
    mcodec: multiCodec("poseidon2-alt_bn_128-merkle-2kb"),
    size: 32,
    coder: poseidon2_merkle_2kb_sponge,
  ),
]
