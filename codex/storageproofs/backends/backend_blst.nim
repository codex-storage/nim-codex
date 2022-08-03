## Nim-POS
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# Implementation of the BLS-based public PoS scheme from
# Shacham H., Waters B., "Compact Proofs of Retrievability"
# using pairing over BLS12-381 ECC

import pkg/blscurve
import pkg/blscurve/blst/blst_abi

type
  ec_SecretKey* = blscurve.SecretKey
  ec_PublicKey* = blscurve.PublicKey
  ec_p1* = blst_p1
  ec_p2* = blst_p2
  ec_p1_affine* = blst_p1_affine
  ec_p2_affine* = blst_p2_affine
  ec_scalar* = blst_scalar
  ec_fr* = blst_fr
  ec_signature* = Signature

const
  EC_SUCCESS*: bool = true

# these need to be template as a workaround for const
template EC_G1* : blst_p1_affine = BLS12_381_G1
template EC_G2* : blst_p2_affine = BLS12_381_G2

func ec_p1_serialize*(dst: var array[96, byte]; src: ec_p1) =
  blst_p1_serialize(dst, src)

func ec_p1_deserialize*(dst: var ec_p1_affine; src: array[96, byte]): bool =
  blst_p1_deserialize(dst, src) == BLST_SUCCESS

func ec_p2_serialize*(dst: var array[192, byte]; src: ec_p2) =
  blst_p2_serialize(dst, src)

func ec_p2_deserialize*(dst: var ec_p2_affine; src: array[192, byte]): bool =
  blst_p2_deserialize(dst, src) == BLST_SUCCESS

func ec_export_uncompressed*(publicKey: ec_PublicKey): array[96, byte] {.inline, noinit.} =
  blscurve.exportUncompressed(publicKey)

func ec_export_uncompressed*(signature: ec_Signature): array[192, byte] {.inline, noinit.} =
  blscurve.exportUncompressed(signature)

func ec_p1_from_affine*(dst: var ec_p1, src: ec_p1_affine) =
  blst_p1_from_affine(dst, src)

func ec_scalar_from_bendian*(ret: var ec_scalar, a: array[32, byte]) =
  blst_scalar_from_bendian(ret, a)

func ec_bendian_from_scalar*(ret: var array[32, byte], a: ec_scalar) =
  blst_bendian_from_scalar(ret, a)

func ec_scalar_fr_check*(a: ec_scalar): CTBool =
  blst_scalar_fr_check(a)

func ec_p2_from_affine*(dst: var ec_p2, src: ec_p2_affine) =
  blst_p2_from_affine(dst, src)

func ec_p2_mult*(dst: var blst_p2, p: blst_p2, scalar: blst_scalar, nbits: uint) =
  blst_p2_mult(dst, p, scalar, nbits)

func ec_p1_mult*(dst: var ec_p1, p: ec_p1, scalar: ec_scalar, nbits: uint) =
  blst_p1_mult(dst, p, scalar, nbits)

func ec_p1_add_or_double*(dst: var ec_p1, a: ec_p1, b: ec_p1) =
  blst_p1_add_or_double(dst, a, b)

func ec_fr_from_scalar*(ret: var ec_fr, a: ec_scalar) =
  blst_fr_from_scalar(ret, a)

func ec_fr_mul*(ret: var ec_fr, a: ec_fr, b: ec_fr) =
  blst_fr_mul(ret, a, b)

func ec_scalar_from_fr*(ret: var ec_scalar, a: ec_fr) =
  blst_scalar_from_fr(ret, a)

func ec_fr_add*(ret: var ec_fr, a: ec_fr, b: ec_fr) =
  blst_fr_add(ret, a, b)

func ec_p1_on_curve*(p: ec_p1): CTBool =
  blst_p1_on_curve(p)

func ec_keygen*(ikm: openarray[byte], publicKey: var ec_PublicKey, secretKey: var ec_SecretKey): bool =
  blscurve.keyGen(ikm, publicKey, secretKey)

func ec_export_raw*(signature: Signature): array[96, byte] {.inline, noinit.} =
    blscurve.exportRaw(signature)

proc ec_sign*[T: byte|char](secretKey: SecretKey, message: openarray[T]): Signature =
    blscurve.sign(secretKey, message)

proc ec_hash_to_g1*[T,U,V: byte|char](dst: var blst_p1;
                       msg: openArray[T];
                       domainSepTag: openArray[U];
                       aug: openArray[V]) =
  blst_hash_to_g1(dst, msg, domainSepTag, aug)

proc pairing(a: ec_p1, b: ec_p2): blst_fp12 =
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

proc verifyPairingsNeg(a1: ec_p1, a2: ec_p2, b1: ec_p1, b2: ec_p2) : bool =
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

proc verifyPairings*(a1: ec_p1, a2: ec_p2, b1: ec_p1, b2: ec_p2) : bool =
  ## Wrapper to select verify pairings implementation
  verifyPairingsNaive(a1, a2, b1, b2)
  #verifyPairingsNeg(a1, a2, b1, b2)

func ec_from_bytes*(
       obj: var (Signature|ProofOfPossession),
       raw: array[96, byte] or array[192, byte]
      ): bool {.inline.} =
  fromBytes(obj, raw)

func ec_from_bytes*(
       obj: var PublicKey,
       raw: array[48, byte] or array[96, byte] or openArray[byte]
      ): bool {.inline.} =
  fromBytes(obj, raw)

func ec_verify*[T: byte|char](
       publicKey: PublicKey,
       message: openarray[T],
       signature: Signature) : bool =
  verify(publicKey, message, signature)