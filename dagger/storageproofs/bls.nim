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
# using pairing over BLS12-381 ECC
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

import blscurve
import blscurve/blst/blst_abi
import ../rng
import endians

# sector size in bytes. Must be smaller than the subgroup order r
# which is 255 bits long for BLS12-381
const bytespersector = 31

# length in bytes of the unique (random) name
const namelen = 512

type
  # a single sector
  ZChar = array[bytespersector, byte]

  # secret key combining the metadata signing key and the POR generation key
  SecretKey = object
    signkey: blscurve.SecretKey
    key: blst_scalar

  # public key combining the metadata signing key and the POR validation key
  PublicKey = object
    signkey: blscurve.PublicKey
    key: blst_p2

  # POR metadata (called "file tag t_0" in the original paper)
  TauZero = object
    name: array[namelen, byte]
    n:    int64
    u:    seq[blst_p1]

  # signed POR metadata (called "signed file tag t" in the original paper)
  Tau = object
    t: TauZero
    signature: array[96, byte]

  # PoR query element
  QElement = object
    I: int64
    V: blst_scalar

proc fromBytesBE(a: array[32, byte]): blst_scalar =
  ## Convert data to blst native form
  blst_scalar_from_bendian(result, a)
  doAssert(blst_scalar_fr_check(result).bool)

proc fromBytesBE(a: openArray[byte]): blst_scalar =
  ## Convert data to blst native form
  var b: array[32, byte]
  doAssert(a.len <= b.len)
  let d = b.len - a.len
  for i in 0 ..< a.len:
    b[i+d] = a[i]
  blst_scalar_from_bendian(result, b)
  doAssert(blst_scalar_fr_check(result).bool)

proc getSector(f: File, blockid: int64, sectorid: int64, spb: int64): ZChar =
  ## Read file sector at given <blockid, sectorid> postion
  f.setFilePos((blockid * spb + sectorid) * sizeof(result))
  let r = f.readBytes(result, 0, sizeof(result))

proc rndScalar(): blst_scalar =
  ## Generate random scalar within the subroup order r
  var scal{.noInit.}: array[32, byte]
  var scalar{.noInit.}: blst_scalar

  while true:
    for val in scal.mitems:
      val = byte Rng.instance.rand(0xFF)
    scalar.blst_scalar_from_bendian(scal)
    if blst_scalar_fr_check(scalar).bool:
      break

  return scalar

proc rndP2(): (blst_p2, blst_scalar) =
  ## Generate random point on G2
  var x{.noInit.}: blst_p2
  x.blst_p2_from_affine(BLS12_381_G2) # init from generator
  let scalar = rndScalar()
  x.blst_p2_mult(x, scalar, 255)
  return (x, scalar)

proc rndP1(): (blst_p1, blst_scalar) =
  ## Generate random point on G1
  var x{.noInit.}: blst_p1
  x.blst_p1_from_affine(BLS12_381_G1) # init from generator
  let scalar = rndScalar()
  x.blst_p1_mult(x, scalar, 255)
  return (x, scalar)

proc posKeygen(): (blst_p2, blst_scalar) =
  ## Generate POS key pair
  rndP2()

proc keygen*(): (PublicKey, SecretKey) =
  ## Generate key pair for signing metadata and for POS tags
  var pk: PublicKey
  var sk: SecretKey
  var ikm: array[32, byte]

  for b in ikm.mitems:
    b = byte Rng.instance.rand(0xFF)
  doAssert ikm.keyGen(pk.signkey, sk.signkey)

  (pk.key, sk.key) = posKeygen()
  return (pk, sk)

proc split(f: File, s: int64): int64 =
  ## Calculate number of blocks for a file
  let size = f.getFileSize()
  let n = ((size - 1) div (s * sizeof(ZChar))) + 1
  echo "File size=", size, " bytes",
    ", blocks=", n,
    ", sectors/block=", $s,
    ", sectorsize=", $sizeof(ZChar), " bytes"

  return n

proc hashToG1[T: byte|char](msg: openArray[T]): blst_p1 =
  ## Hash to curve with Dagger specific domain separation
  const dst = "DAGGER-PROOF-OF-CONCEPT"
  result.blst_hash_to_g1(msg, dst, aug = "")

proc hashNameI(name: array[namelen, byte], i: int64): blst_p1 =
  ## Calculate unique filname and block index based hash

  # # naive implementation, hashing a long string representation
  # # such as "[255, 242, 23]1"
  # return hashToG1($name & $i)

  # more compact and faster implementation
  var namei: array[sizeof(name) + sizeof(int64), byte]
  namei[0..sizeof(name)-1] = name
  bigEndian64(addr(namei[sizeof(name)]), unsafeAddr(i))
  return hashToG1(namei)

proc generateAuthenticatorNaive(i: int64, s: int64, t: TauZero, f: File, ssk: SecretKey): blst_p1 =
  ## Naive implementation of authenticator as in the S&W paper.
  ## With the paper's multiplicative notation:
  ##   \sigmai=\(H(file||i)\cdot\prod{j=0}^{s-1}{uj^{m[i][j]}})^{\alpha}
  var sum: blst_p1
  for j in 0 ..< s:
    var prod: blst_p1
    prod.blst_p1_mult(t.u[j], fromBytesBE(getSector(f, i, j, s)), 255)
    sum.blst_p1_add_or_double(sum, prod)

  blst_p1_add_or_double(result, hashNameI(t.name, i), sum)
  result.blst_p1_mult(result, ssk.key, 255)

proc generateAuthenticatorOpt(i: int64, s: int64, t: TauZero, ubase: openArray[blst_scalar], f: File, ssk: SecretKey): blst_p1 =
  ## Optimized implementation of authenticator generation
  ## This implementation is reduces the number of scalar multiplications
  ## from s+1 to 1+1 , using knowledge about the scalars (r_j)
  ## used to generate u_j as u_j = g^{r_j}
  ##
  ## With the paper's multiplicative notation, we use:
  ##   (H(file||i)\cdot g^{\sum{j=0}^{s-1}{r_j \cdot m[i][j]}})^{\alpha}
  var sum: blst_fr
  var sums: blst_scalar
  for j in 0 ..< s:
    var a, b, x: blst_fr
    a.blst_fr_from_scalar(ubase[j])
    b.blst_fr_from_scalar(fromBytesBE(getSector(f, i, j, s)))
    x.blst_fr_mul(a, b)
    sum.blst_fr_add(sum, x)
  sums.blst_scalar_from_fr(sum)

  result.blst_p1_from_affine(BLS12_381_G1)
  result.blst_p1_mult(result, sums, 255)

  result.blst_p1_add_or_double(result, hashNameI(t.name, i))
  result.blst_p1_mult(result, ssk.key, 255)

proc generateAuthenticator(i: int64, s: int64, t: TauZero, ubase: openArray[blst_scalar], f: File, ssk: SecretKey): blst_p1 =
  ## Wrapper to select tag generator implementation

  # let a = generateAuthenticatorNaive(i, s, t, f, ssk)
  let b = generateAuthenticatorOpt(i, s, t, ubase, f, ssk)
  # doAssert(a.blst_p1_is_equal(b).bool)
  return b

proc setup*(ssk: SecretKey, s:int64, filename: string): (Tau, seq[blst_p1]) =
  ## Set up the POR scheme by generating tags and metadata
  let file = open(filename)
  let n = split(file, s)
  var t = TauZero(n: n)

  # generate a random name
  for i in 0 ..< 512 :
    t.name[i] = byte Rng.instance.rand(0xFF)

  # generate the coefficient vector for combining sectors of a block: U
  var ubase: seq[blst_scalar]
  for i  in 0 ..< s :
    let (u, ub) = rndP1()
    t.u.add(u)
    ubase.add(ub)
   
  #TODO: a better bytearray conversion of TauZero for the signature might be needed
  #      the current conversion using $t might be architecture dependent and not unique
  let signature = sign(ssk.signkey, $t)
  let tau = Tau(t: t, signature: signature.exportRaw())

  #generate sigmas
  var sigmas: seq[blst_p1]
  for i in 0 ..< n :
    sigmas.add(generateAuthenticator(i, s, t, ubase, file, ssk))

  file.close()
  result = (tau, sigmas)

proc generateQuery*(tau: Tau, spk: PublicKey, l: int): seq[QElement] =
  ## Generata a random BLS query of given sizxe
  let n = tau.t.n # number of blocks

  for i in 0 ..< l :
    var q: QElement
    q.I = Rng.instance.rand(n-1) #TODO: dedup
    q.V = rndScalar() #TODO: fix range
    result.add(q)

proc generateProof*(q: openArray[QElement], authenticators: openArray[blst_p1], spk: PublicKey, s: int64, filename: string): (seq[blst_scalar], blst_p1) =
  ## Generata BLS proofs for a given query
  let file = open(filename)

  var mu: seq[blst_scalar]
  for j in 0 ..< s :
    var muj: blst_fr
    for qelem in q :
      var x, v, sector: blst_fr
      let sect = fromBytesBE(getSector(file, qelem.I, j, s))
      sector.blst_fr_from_scalar(sect)
      v.blst_fr_from_scalar(qelem.V)
      x.blst_fr_mul(v, sector)
      muj.blst_fr_add(muj, x)
    var mujs: blst_scalar
    mujs.blst_scalar_from_fr(muj)
    mu.add(mujs)

  var sigma: blst_p1
  for qelem in q:
    var prod: blst_p1
    prod.blst_p1_mult(authenticators[qelem.I], qelem.V, 255)
    sigma.blst_p1_add_or_double(sigma, prod)

  file.close()
  return (mu, sigma)

proc pairing(a: blst_p1, b: blst_p2): blst_fp12 =
  ## Calculate pairing G_1,G_2 -> G_T
  var aa: blst_p1_affine
  var bb: blst_p2_affine
  blst_p1_to_affine(aa, a)
  blst_p2_to_affine(bb, b)
  var l: blst_fp12
  blst_miller_loop(l, bb, aa)
  blst_final_exp(result, l)

proc verifyPairingsNaive(a1: blst_p1, a2: blst_p2, b1: blst_p1, b2: blst_p2) : bool =
  let e1 = pairing(a1, a2)
  let e2 = pairing(b1, b2)
  return e1 == e2

proc verifyPairingsNeg(a1: blst_p1, a2: blst_p2, b1: blst_p1, b2: blst_p2) : bool =
  ## Faster pairing verification using 2 miller loops but ony one final exponentiation
  ## based on https://github.com/benjaminion/c-kzg/blob/main/src/bls12_381.c
  var
    loop0, loop1, gt_point: blst_fp12
    aa1, bb1: blst_p1_affine
    aa2, bb2: blst_p2_affine

  var a1neg = a1
  blst_p1_cneg(a1neg, 1)

  blst_p1_to_affine(aa1, a1neg)
  blst_p1_to_affine(bb1, b1)
  blst_p2_to_affine(aa2, a2)
  blst_p2_to_affine(bb2, b2)

  blst_miller_loop(loop0, aa2, aa1)
  blst_miller_loop(loop1, bb2, bb1)

  blst_fp12_mul(gt_point, loop0, loop1)
  blst_final_exp(gt_point, gt_point)

  return blst_fp12_is_one(gt_point).bool

proc verifyPairings(a1: blst_p1, a2: blst_p2, b1: blst_p1, b2: blst_p2) : bool =
  ## Wrapper to select verify pairings implementation
  verifyPairingsNaive(a1, a2, b1, b2)
  #verifyPairingsNeg(a1, a2, b1, b2)

proc verifyProof*(tau: Tau, q: openArray[QElement], mus: openArray[blst_scalar], sigma: blst_p1, spk: PublicKey): bool =
  ## Verify a BLS proof given a query

  # verify signature on Tau
  var signature: Signature
  if not signature.fromBytes(tau.signature):
    return false
  if not verify(spk.signkey, $tau.t, signature):
    return false

  var first: blst_p1
  for qelem in q :
    var prod: blst_p1
    prod.blst_p1_mult(hashNameI(tau.t.name, qelem.I), qelem.V, 255)
    first.blst_p1_add_or_double(first, prod)
    doAssert(blst_p1_on_curve(first).bool)

  let us = tau.t.u
  var second: blst_p1
  for j in 0 ..< len(us) :
    var prod: blst_p1
    prod.blst_p1_mult(us[j], mus[j], 255)
    second.blst_p1_add_or_double(second, prod)
    doAssert(blst_p1_on_curve(second).bool)

  var sum: blst_p1
  sum.blst_p1_add_or_double(first, second)

  var g{.noInit.}: blst_p2
  g.blst_p2_from_affine(BLS12_381_G2)

  return verifyPairings(sum, spk.key, sigma, g)
