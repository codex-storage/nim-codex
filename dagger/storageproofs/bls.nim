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
# In Z_p:
# - m_{ij}: sectors of file
# - α: pos secret key
# - name
# - μ_j 
#
# In G_1: multiplicative cyclic group
# - H: {0,1}∗ →G_1 
# - u_1,…,u_s ←R G_1 
# - σ_i: authenticators
# - σ: part of proof
#
# In G_2: multiplicative cyclic group
# - g: generator
# - v ← g^α: pos public key
#
# In G_T:
# - two pairings for validation

import blscurve
import blscurve/blst/blst_abi
import random

const sectorsperblock = 1024.int64
const bytespersector = 31 # r is 255 bits long 
const querylen = 22

type ZChar = array[bytespersector, byte]

type SecretKey = object
  signkey: blscurve.SecretKey
  key: blst_scalar

type PublicKey = object
  signkey: blscurve.PublicKey
  key: blst_p2

type TauZero = object
  name: array[512,byte]
  n:    int64
  u:    seq[blst_p1]

type Tau = object
  t: TauZero
  signature: array[512, byte]

proc fromBytesBE(a: array[32, byte]): blst_scalar =
  blst_scalar_from_bendian(result, a)
  doAssert(blst_scalar_fr_check(result).bool)

proc fromBytesBE(a: openArray[byte]): blst_scalar =
  var b: array[32, byte]
  doAssert(a.len <= b.len)
  let d = b.len - a.len
  for i in 0 ..< a.len:
    b[i+d] = a[i]
  blst_scalar_from_bendian(result, b)
  doAssert(blst_scalar_fr_check(result).bool)

proc getSector(f: File, blockid: int64, sectorid: int64, spb: int64): ZChar =
  f.setFilePos(blockid * spb + sectorid)
  let r = f.readBytes(result, 0, sizeof(result))

proc rndScalar(): blst_scalar =
  var scal{.noInit.}: array[32, byte]
  var scalar{.noInit.}: blst_scalar

  while true:
    for val in scal.mitems:
      val = byte rand(0xFF)
    scalar.blst_scalar_from_bendian(scal)
    if blst_scalar_fr_check(scalar).bool:
      break

  return scalar

proc rndP2(): (blst_p2, blst_scalar) =
  var x{.noInit.}: blst_p2
  x.blst_p2_from_affine(BLS12_381_G2) # init from generator
  let scalar = rndScalar()
  x.blst_p2_mult(x, scalar, 255) 
  return (x, scalar)

proc rndP1(): (blst_p1, blst_scalar) =
  var x{.noInit.}: blst_p1
  x.blst_p1_from_affine(BLS12_381_G1) # init from generator
  let scalar = rndScalar()
  x.blst_p1_mult(x, scalar, 255) 
  return (x, scalar)

proc posKeygen(): (blst_p2, blst_scalar) =
  rndP2()

proc keygen*(): (PublicKey, SecretKey) =
  var pk: PublicKey
  var sk: SecretKey
  var ikm: array[32, byte]
  var RNG = initRand(0xFACADE)

  for b in ikm.mitems:
    b = byte RNG.rand(0xFF)
  doAssert ikm.keyGen(pk.signkey, sk.signkey)

  (pk.key, sk.key) = posKeygen()
  return (pk, sk)

proc split(f: File): (int64, int64) =
  let size = f.getFileSize()
  let n = ((size - 1) div (sectorsperblock * sizeof(ZChar))) + 1
  echo "File size=", size, " bytes",
    ", blocks=", n,
    ", sectors/block=", $sectorsperblock,
    ", sectorsize=", $sizeof(ZChar), " bytes" 
 
  return (sectorsperblock, n)

proc hashToG1(msg: string): blst_p1 =
  const dst = "BLS_SIG_BLS12381G2-SHA256-SSWU-RO_POP_"
  result.blst_hash_to_g1(msg, dst, aug = "")
 
proc hashNameI(name: openArray[byte], i: int64): blst_p1 =
  return hashToG1($name & $i)

proc generateAuthenticator(i: int64, s: int64, t: TauZero, f: File, ssk: SecretKey): blst_p1 =

  var sum: blst_p1
  for j in 0 ..< s:
    var prod: blst_p1
    prod.blst_p1_mult(t.u[j], fromBytesBE(getSector(f, i, j, s)), 255)
    sum.blst_p1_add(sum, prod)

  blst_p1_add(result, hashNameI(t.name, i), sum)
  result.blst_p1_mult(result, ssk.key, 255)

proc st*(ssk: SecretKey, filename: string): (Tau, seq[blst_p1]) =
  let file = open(filename)
  let (s, n) = split(file)
  var t = TauZero(n: n)

  # generate a random name
  for i in 0 ..< 512 :
    t.name[i] = rand(byte)

  # generate the coefficient vector for combining sectors of a block: U
  for i  in 0 ..< s :
    let (u, _) = rndP1()
    t.u.add(u)
   
  #TODO: sign for tau
  let tau = Tau(t: t)

  #generate sigmas
  var sigmas: seq[blst_p1]
  for i in 0 ..< n :
    sigmas.add(generateAuthenticator(i, s, t, file, ssk))

  file.close()
  result = (tau, sigmas)

type QElement = object
  I: int64
  V: blst_scalar

proc generateQuery*(
    tau: Tau,
    spk: PublicKey,
    l: int = querylen # query elements
  ): seq[QElement] =
  # verify signature on Tau

  let n = tau.t.n # number of blocks

  for i in 0 ..< l :
    var q: QElement
    q.I = rand((int)n-1) #TODO: dedup
    q.V = rndScalar() #TODO: fix range
    result.add(q)

proc generateProof*(q: openArray[QElement], authenticators: openArray[blst_p1], spk: PublicKey, filename: string): (seq[blst_scalar], blst_p1) =
  let file = open(filename)
  let s = sectorsperblock

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
    sigma.blst_p1_add(sigma, prod)

  file.close()
  return (mu, sigma)

proc pairing(q: blst_p2, p: blst_p1): blst_fp12 =
  var qa: blst_p2_affine
  var pa: blst_p1_affine
  blst_p2_to_affine(qa, q)
  blst_p1_to_affine(pa, p)
  var l: blst_fp12 
  blst_miller_loop(l, qa, pa)
  blst_final_exp(result, l)

proc verifyProof*(tau: Tau, q: openArray[QElement], mus: openArray[blst_scalar], sigma: blst_p1, spk: PublicKey): bool =
  var first: blst_p1
  for qelem in q :
    var prod: blst_p1
    prod.blst_p1_mult(hashNameI(tau.t.name, qelem.I), qelem.V, 255)
    first.blst_p1_add(first, prod)
    doAssert(blst_p1_on_curve(first).bool)

  let us = tau.t.u
  var second: blst_p1
  for j in 0 ..< len(us) :
    var prod: blst_p1
    prod.blst_p1_mult(us[j], mus[j], 255)
    second.blst_p1_add(second, prod)
    doAssert(blst_p1_on_curve(second).bool)

  var sum: blst_p1
  sum.blst_p1_add(first, second)

  let e1 = pairing(spk.key, sum)
  
  var g{.noInit.}: blst_p2
  g.blst_p2_from_affine(BLS12_381_G2) 
  let e2 = pairing(g, sigma)
  return e1 == e2
