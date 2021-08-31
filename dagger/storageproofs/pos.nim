## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import libp2p/crypto/crypto # for RSA
import bearssl
import memfiles
import math
import nimcrypto # for SHA512
import random

import ./bigint/stint2
#import ./bigint/bigints2

const keysize = 2048
const sectorsperblock = 4
const bytespersector = 128
const querylen = 22
assert bytespersector < keysize div 8 # TODO: not strict

type ZChar = array[bytespersector, byte]

proc fromBytesBE(nptr: ptr cuchar, nlen: int): BigInt =
  let nptra = cast[ptr array[0xffffffff,byte]](nptr)
  result = fromBytesBE(nptra[], nlen)

proc getSector(filep: ptr ZChar, blockid: int64, sectorid: int64, spb: int64): Zchar =
  result = cast[ptr array[0xffffffff, ZChar]](filep)[blockid * spb + sectorid]

proc fromBytesBE(sector: ZChar): BigInt =
  result = fromBytesBE(sector, sizeof(ZChar))

proc getModulus(pubkey: PublicKey): BigInt =
  result = fromBytesBE(pubkey.rsakey.key.n, pubkey.rsakey.key.nlen)

proc getModulus(seckey: PrivateKey): BigInt =  
  result = fromBytesBE(seckey.rsakey.pubk.n, seckey.rsakey.pubk.nlen)

proc getPubex(pubkey: PublicKey): BigInt =
  ## get RSA E exponent
  result = fromBytesBE(pubkey.rsakey.key.e, pubkey.rsakey.key.elen)

proc getPrivex(seckey: PrivateKey): BigInt =
  ## get RSA D exponent
  result = fromBytesBE(seckey.rsakey.pexp, seckey.rsakey.pexplen)

proc rsaDecode(msg: var array[256,byte], ssk: PrivateKey): array[256,byte] =
  let RsaPrivate = rsaPrivateGetDefault()
  let r = RsaPrivate(cast[ptr cuchar](addr(msg)), addr(ssk.rsakey.seck))
  result = msg

proc rsaDecode(msg: BigInt, ssk: PrivateKey): BigInt =
  assert msg < ssk.getModulus()
  var msgarray = msg.to256BytesBE()
  let enc = rsaDecode(msgarray, ssk)
  result = fromBytesBE(enc, 256)
  assert result < ssk.getModulus()

proc rsaEncode(msg: var array[256,byte], spk: PublicKey): array[256,byte] =
  let RsaPublic = rsaPublicGetDefault()
  let r = RsaPublic(cast[ptr cuchar](addr(msg)), 256, addr(spk.rsakey.key))
  result = msg

proc rsaEncode(msg: BigInt, spk: PublicKey): BigInt =
  assert msg < spk.getModulus()
  var msgarray = msg.to256BytesBE()
  let enc = rsaEncode(msgarray, spk)
  result = fromBytesBE(enc, 256)
  assert result < spk.getModulus()

type TauZero = object
  name: array[512,byte]
  n:    int64
  u:    seq[BigInt]

type Tau = object
  t: TauZero
  signature: array[512, byte]

proc rsaKeygen*(): (PublicKey, PrivateKey) =
  let rng = newRng()
  var seckey = PrivateKey.random(RSA, rng[], keysize).get()
  var pubkey = seckey.getKey().get()
  return (pubkey, seckey)

proc openFile(file: string, s = sectorsperblock, c = sizeof(ZChar)): (ptr ZChar, int64, int64) =
  let mm = memfiles.open(file)
  
  let size = mm.size
  let n = int64(ceil(float64(size / (s * c))))
 
  return (cast[ptr ZChar](mm.mem), int64(s), n)

proc hashNameI(name: openArray[byte], i: int64): BigInt =
  let hashString = $sha512.digest($name & $i)
  return fromBytesBE(cast[seq[byte]](hashString), hashString.len()) # TODO: use better way to convert

proc generateAuthenticator(i: int64, s: int64, t: TauZero, filep: ptr ZChar, ssk: PrivateKey): BigInt =
  let N = ssk.getModulus()

  var productory = BigInt.one
  for j in 0 ..< s:
    productory = mulmod(productory,
                        powmod(t.u[j], fromBytesBE(getSector(filep, i, j, s)), N),
                        N)

  # result = (hashNameI(t.name, i) * productory).powmod(getPrivex(ssk), N)
  result = rsaDecode((hashNameI(t.name, i) * productory) mod N, ssk)

proc st*(ssk: PrivateKey, file: string): (Tau, seq[BigInt]) =
  let (filep, s, n) = openFile(file)
  var t = TauZero(n: n)

  # generate a random name
  for i in 0 ..< 512 :
    t.name[i] = rand(byte)

  # generate the coefficient vector for combining sectors of a block: U
  for i  in 0 ..< s :
    t.u.add(initBigInt(rand(uint32))) #TODO: fix limit
    
  #TODO: sign for tau
  let tau = Tau(t: t)

  #generate sigmas
  var sigmas: seq[BigInt]
  for i in 0 ..< n :
    sigmas.add(generateAuthenticator(i, s, t, filep, ssk)) #TODO: int64 sizes?

  result = (tau, sigmas)

type QElement = object
  I: int64
  V: BigInt

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
    q.V = initBigInt(rand(uint64)) #TODO: fix range
    result.add(q)

proc generateProof*(q: openArray[QElement], authenticators: openArray[BigInt], spk: PublicKey, file: string): (seq[BigInt], BigInt) =
  let (filep, s, _) = openFile(file)
  let N = spk.getModulus()

  var mu: seq[BigInt]
  for j in 0 ..< s :
    var muj = BigInt.zero
    for qelem in q :
      let sector = fromBytesBE(getSector(filep, qelem.I, j, s))
      muj += qelem.V * sector
      #muj = addmod(muj, mulmod(qelem.V, sector, N), N)
    mu.add(muj)

  var sigma = BigInt.one
  for qelem in q:
    sigma = mulmod(sigma,
                   powmod(authenticators[qelem.I], qelem.V, N),
                   N)

  return (mu, sigma)

proc verifyProof*(tau: Tau, q: openArray[QElement], mus: openArray[BigInt], sigma: BigInt, spk: PublicKey): bool =
  # TODO: check that values are in range
  let N = spk.getModulus()

  var first = BigInt.one
  for qelem in q :
    first = mulmod(first, 
                   powmod(hashNameI(tau.t.name, qelem.I), qelem.V, N),
                   N)

  let us = tau.t.u
  var second = BigInt.one
  for j in 0 ..< len(us) :
    second = mulmod(second,
                    powmod(us[j], mus[j], N),
                    N)

  return mulmod(first, second, N) == rsaEncode(sigma, spk)
