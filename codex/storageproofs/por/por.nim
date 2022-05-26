## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# Implementation of the BLS-based public PoS scheme from
# Shacham H., Waters B., "Compact Proofs of Retrievability"
# using pairing over the BLS12-381 ECC or BN254_Starks
#
# The implementation supports two backends:
#  - BLST (default)
#  - Constantine (-d:por_backend_constantine)
#
# The implementation supports PoR over the following curves:
#  - BLS12-381 (default)
#  - BN254_Starks (use -d:por_backend_constantine -d:por_curve_bn254)
#
# Notation from the paper
# In Z:
# - n: number of blocks
# - s: number of sectors per block
#
# In Z_p: modulo curve order
# - m_{ij}: sectors of the file i:0..n-1 j:0..s-1
# - α: PoS secret key
# - name: random string
# - μ_j: part of proof, j:0..s-1
#
# In G_1: multiplicative cyclic group
# - H: {0,1}∗ →G_1 : hash function
# - u_1,…,u_s ←R G_1 : random coefficients
# - σ_i: authenticators
# - σ: part of proof
#
# In G_2: multiplicative cyclic group
# - g: generator of G_2
# - v ← g^α: PoS public key
#
# In G_T:
# - used only to calculate the two pairings during validation
#
# Implementation:
# Our implementation uses additive cyclic groups instead of the multiplicative
# cyclic group in the paper, thus changing the name of the group operation as in
# blscurve and blst. Thus, point multiplication becomes point addition, and scalar
# exponentiation becomes scalar multiplicaiton.
#
# Number of operations:
# The following table summarizes the number of operations in different phases
# using the following notation:
#  - f: file size expressed in units of 31 bytes
#  - n: number of blocks
#  - s: number of sectors per block
#  - q: number of query items
#
# Since f = n * s and s is a parameter of the scheme, it is better to express
# the cost as a function of f and s. This only matters for Setup, all other
# phases are independent of the file size assuming a given q.
#
# |                |         Setup             | Challenge |   Proof   | Verify    |
# |----------------|-----------|---------------|-----------|-----------|-----------|
# | G1 random      | s         = s             | q         |           |           |
# | G1 scalar mult | n * (s+1) = f * (1 + 1/s) |           | q         | q + s     |
# | G1 add         | n * s     = f             |           | q-1       | q-1 + s-1 |
# | Hash to G1     | n         = f / s         |           |           | q         |
# | Z_p mult       |           =               |           | s * q     |           |
# | Z_p add        |           =               |           | s * (q-1) |           |
# | pairing        |           =               |           |           | 2         |
#
#
# Storage and communication cost:
# The storage overhead for a file of f_b bytes is given by the n authenticators
# calculated in the setup phase.
#   f_b = f * 31 = n * s * 31
# Each authenticator is a point on G_1, which occupies 48 bytes in compressed form.
# Thus, the overall sorage size in bytes is:
#   f_pos = fb + n * 48 = fb * (1 + (48/31) * (1/s))
#
# Communicaiton cost in the Setup phase is simply related to the storage cost.
# The size of the challenge is
#   q * (8 + 48) bytes
# The size of the proof is instead
#   s * 32 + 48 bytes
import std/endians

# Select backend to use
#  - blst supports only the BLS12-381 curve
#  - constantine is more experimental, supports BLS and BN curves as well
# As of now configuration of backends is in the backend_* file itself
when defined(por_backend_constantine):
  import ../backends/backend_constantine
else:
  import ../backends/backend_blst

import pkg/chronos
import pkg/blscurve
import pkg/blscurve/blst/blst_abi

import ../../rng
import ../../streams

# sector size in bytes. Must be smaller than the subgroup order r
# which is 255 bits long for BLS12-381
const
  BytesPerSector* = 31

  # length in bytes of the unique (random) name
  Namelen = 512


type
  # a single sector
  ZChar* = array[BytesPerSector, byte]

  # secret key combining the metadata signing key and the POR generation key
  SecretKey* = object
    signkey*: ec_SecretKey
    key*: ec_scalar

  # public key combining the metadata signing key and the POR validation key
  PublicKey* = object
    signkey*: ec_PublicKey
    key*: ec_p2

  # POR metadata (called "file tag t_0" in the original paper)
  TauZero* = object
    name*: array[Namelen, byte]
    n*:    int64
    u*:    seq[ec_p1]

  # signed POR metadata (called "signed file tag t" in the original paper)
  Tau* = object
    t*: TauZero
    signature*: array[96, byte]

  Proof* = object
    mu*: seq[blst_scalar]
    sigma*: blst_p1

  # PoR query element
  QElement* = object
    I*: int64
    V*: ec_scalar

  PoR* = object
    ssk*: SecretKey
    spk*: PublicKey
    tau*: Tau
    authenticators*: seq[ec_p1]

proc fromBytesBE(a: array[32, byte]): ec_scalar =
  ## Convert data to native form
  ##

  ec_scalar_from_bendian(result, a)
  doAssert(ec_scalar_fr_check(result).bool)

proc fromBytesBE(a: openArray[byte]): ec_scalar =
  ## Convert data to native form
  ##

  var b: array[32, byte]
  doAssert(a.len <= b.len)

  let d = b.len - a.len
  for i in 0..<a.len:
    b[i+d] = a[i]

  ec_scalar_from_bendian(result, b)
  doAssert(ec_scalar_fr_check(result).bool)

proc getSector(
  stream: SeekableStream,
  blockId: int64,
  sectorId: int64,
  spb: int64): Future[ZChar] {.async.} =
  ## Read file sector at given <blockid, sectorid> postion
  ##

  var res: ZChar
  stream.setPos(((blockid * spb + sectorid) * ZChar.len).int)
  discard await stream.readOnce(addr res[0], ZChar.len)
  return res

proc rndScalar(scalar: var ec_scalar): void =
  ## Generate random scalar within the subroup order r
  ##

  var scal {.noInit.}: array[32, byte]

  while true:
    for val in scal.mitems:
      val = byte Rng.instance.rand(0xFF)

    scalar.ec_scalar_from_bendian(scal)
    if ec_scalar_fr_check(scalar).bool:
      break

proc rndP2(x: var ec_p2, scalar: var ec_scalar): void =
  ## Generate random point on G2
  ##

  x.ec_p2_from_affine(EC_G2) # init from generator
  scalar.rndScalar()
  x.ec_p2_mult(x, scalar, 255)

proc rndP1(x: var ec_p1, scalar: var ec_scalar): void =
  ## Generate random point on G1
  ##

  x.ec_p1_from_affine(EC_G1) # init from generator
  scalar.rndScalar()
  x.ec_p1_mult(x, scalar, 255)

template posKeygen(x: var ec_p2, scalar: var ec_scalar): void =
  ## Generate POS key pair
  ##

  rndP2(x, scalar)

proc keyGen*(): (PublicKey, SecretKey) =
  ## Generate key pair for signing metadata and for POS tags
  ##

  var
    pk: PublicKey
    sk: SecretKey
    ikm: array[32, byte]

  for b in ikm.mitems:
    b = byte Rng.instance.rand(0xFF)

  doAssert ikm.ec_keygen(pk.signkey, sk.signkey)

  posKeygen(pk.key, sk.key)
  return (pk, sk)

proc sectorsCount(stream: SeekableStream, s: int64): int64 =
  ## Calculate number of blocks for a file
  ##

  let
    size = stream.size()
    n = ((size - 1) div (s * sizeof(ZChar))) + 1
  # debugEcho "File size=", size, " bytes",
  #   ", blocks=", n,
  #   ", sectors/block=", $s,
  #   ", sectorsize=", $sizeof(ZChar), " bytes"

  return n

proc hashToG1(msg: openArray[byte]): ec_p1 =
  ## Hash to curve with Dagger specific domain separation
  ##

  const dst = "DAGGER-PROOF-OF-CONCEPT"
  result.ec_hash_to_g1(msg, dst, aug = "")

proc hashNameI(name: array[Namelen, byte], i: int64): ec_p1 =
  ## Calculate unique filname and block index based hash
  ##

  # # naive implementation, hashing a long string representation
  # # such as "[255, 242, 23]1"
  # return hashToG1($name & $i)

  # more compact and faster implementation
  var namei: array[sizeof(name) + sizeof(int64), byte]
  namei[0..sizeof(name)-1] = name
  bigEndian64(addr(namei[sizeof(name)]), unsafeAddr(i))
  return hashToG1(namei)

proc generateAuthenticatorNaive(
  stream: SeekableStream,
  ssk: SecretKey,
  i: int64,
  s: int64,
  t: TauZero): Future[ec_p1] {.async.} =
  ## Naive implementation of authenticator as in the S&W paper.
  ## With the paper's multiplicative notation:
  ##   \sigmai=\(H(file||i)\cdot\prod{j=0}^{s-1}{uj^{m[i][j]}})^{\alpha}
  ##

  var sum: ec_p1
  for j in 0..<s:
    var prod: ec_p1
    prod.ec_p1_mult(t.u[j], fromBytesBE((await stream.getSector(i, j, s))), 255)
    sum.ec_p1_add_or_double(sum, prod)

  ec_p1_add_or_double(result, hashNameI(t.name, i), sum)
  result.ec_p1_mult(result, ssk.key, 255)

proc generateAuthenticatorOpt(
  stream: SeekableStream,
  ssk: SecretKey,
  i: int64,
  s: int64,
  t: TauZero,
  ubase: seq[blst_scalar]): Future[ec_p1] {.async.} =
  ## Optimized implementation of authenticator generation
  ## This implementation is reduces the number of scalar multiplications
  ## from s+1 to 1+1 , using knowledge about the scalars (r_j)
  ## used to generate u_j as u_j = g^{r_j}
  ##
  ## With the paper's multiplicative notation, we use:
  ##   (H(file||i)\cdot g^{\sum{j=0}^{s-1}{r_j \cdot m[i][j]}})^{\alpha}
  ##

  var sum: ec_fr
  var sums: ec_scalar
  for j in 0..<s:
    var a, b, x: ec_fr
    a.ec_fr_from_scalar(ubase[j])
    b.ec_fr_from_scalar(fromBytesBE((await stream.getSector(i, j, s))))
    x.ec_fr_mul(a, b)
    sum.ec_fr_add(sum, x)
  sums.ec_scalar_from_fr(sum)

  result.ec_p1_from_affine(EC_G1)
  result.ec_p1_mult(result, sums, 255)

  result.ec_p1_add_or_double(result, hashNameI(t.name, i))
  result.ec_p1_mult(result, ssk.key, 255)

proc generateAuthenticator(
  stream: SeekableStream,
  ssk: SecretKey,
  i: int64,
  s: int64,
  t: TauZero,
  ubase: seq[ec_scalar]): Future[ec_p1] =
  ## Wrapper to select tag generator implementation
  ##

  # let a = generateAuthenticatorNaive(stream, ssk, i, s, t, ubase)
  return generateAuthenticatorOpt(stream, ssk, i, s, t, ubase)
  # doAssert(a.ec_p1_is_equal(b).bool)

proc generateQuery*(tau: Tau, l: int): seq[QElement] =
  ## Generata a random BLS query of given size
  ##

  let n = tau.t.n # number of blocks

  for i in 0..<l:
    var q: QElement
    q.I = Rng.instance.rand(n-1) #TODO: dedup
    q.V.rndScalar() #TODO: fix range
    result.add(q)

proc generateProof*(
  stream: SeekableStream,
  q: seq[QElement],
  authenticators: seq[ec_p1],
  s: int64): Future[Proof] {.async.} =
  ## Generata BLS proofs for a given query
  ##

  var
    mu: seq[ec_scalar]

  for j in 0..<s:
    var
      muj: ec_fr

    for qelem in q:
      let
        sect = fromBytesBE((await stream.getSector(qelem.I, j, s)))

      var
        x, v, sector: ec_fr

      sector.ec_fr_from_scalar(sect)
      v.ec_fr_from_scalar(qelem.V)
      x.ec_fr_mul(v, sector)
      muj.ec_fr_add(muj, x)

    var
      mujs: ec_scalar

    mujs.ec_scalar_from_fr(muj)
    mu.add(mujs)

  var
    sigma: ec_p1

  for qelem in q:
    var
      prod: ec_p1

    prod.ec_p1_mult(authenticators[qelem.I], qelem.V, 255)
    sigma.ec_p1_add_or_double(sigma, prod)

  return Proof(mu: mu, sigma: sigma)

proc verifyProof*(
  self: PoR,
  q: seq[QElement],
  mus: seq[ec_scalar],
  sigma: ec_p1): bool =
  ## Verify a BLS proof given a query
  ##

  # verify signature on Tau
  var signature: ec_signature
  if not signature.ec_from_bytes(self.tau.signature):
    return false

  if not ec_verify(self.spk.signkey, $self.tau.t, signature):
    return false

  var first: ec_p1
  for qelem in q:
    var prod: ec_p1
    prod.ec_p1_mult(hashNameI(self.tau.t.name, qelem.I), qelem.V, 255)
    first.ec_p1_add_or_double(first, prod)
    doAssert(ec_p1_on_curve(first).bool)

  let us = self.tau.t.u
  var second: ec_p1
  for j in 0..<len(us):
    var prod: ec_p1
    prod.ec_p1_mult(us[j], mus[j], 255)
    second.ec_p1_add_or_double(second, prod)
    doAssert(ec_p1_on_curve(second).bool)

  var sum: ec_p1
  sum.ec_p1_add_or_double(first, second)

  var g {.noInit.}: ec_p2
  g.ec_p2_from_affine(EC_G2)

  return verifyPairings(sum, self.spk.key, sigma, g)

proc init*(
  T: type PoR,
  stream: SeekableStream,
  ssk: SecretKey,
  spk: PublicKey,
  blockSize: int64): Future[PoR] {.async.} =
  ## Set up the POR scheme by generating tags and metadata
  ##

  doAssert(
    (blockSize mod BytesPerSector) == 0,
    "Block size should be divisible by `BytesPerSector`")

  let
    s = blockSize div BytesPerSector
    n = stream.sectorsCount(s)

  # generate a random name
  var t = TauZero(n: n)
  for i in 0..<Namelen:
    t.name[i] = byte Rng.instance.rand(0xFF)

  # generate the coefficient vector for combining sectors of a block: U
  var ubase: seq[ec_scalar]
  for i in 0..<s:
    var
      u: ec_p1
      ub: ec_scalar
  
    rndP1(u, ub)
    t.u.add(u)
    ubase.add(ub)
  
  #TODO: a better bytearray conversion of TauZero for the signature might be needed
  #      the current conversion using $t might be architecture dependent and not unique
  let
    signature = ec_sign(ssk.signkey, $t)
    tau = Tau(t: t, signature: signature.exportRaw())

  # generate sigmas
  var
    sigmas: seq[ec_p1]

  for i in 0..<n:
    sigmas.add((await stream.generateAuthenticator(ssk, i, s, t, ubase)))

  return PoR(
    ssk: ssk,
    spk: spk,
    tau: tau,
    authenticators: sigmas)
