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

import blscurve
import blscurve/blst/blst_abi

type
  ec_SecretKey* = blscurve.SecretKey
  ec_PublicKey* = blscurve.PublicKey
  ec_p1* = blst_p1
  ec_p2* = blst_p2
  ec_scalar* = blst_scalar
  ec_fr* = blst_fr
  ec_signature* = Signature

# these need to be template as a workaround for const
template EC_G1* : blst_p1_affine = BLS12_381_G1
template EC_G2* : blst_p2_affine = BLS12_381_G2

let
  ec_p1_from_affine* = blst_p1_from_affine
  ec_scalar_from_bendian* = blst_scalar_from_bendian
  ec_scalar_fr_check* = blst_scalar_fr_check
  ec_p2_from_affine* = blst_p2_from_affine
  ec_p2_mult* = blst_p2_mult
  ec_p1_mult* = blst_p1_mult
  ec_p1_add_or_double* = blst_p1_add_or_double
  ec_fr_from_scalar* = blst_fr_from_scalar
  ec_fr_mul* = blst_fr_mul
  ec_scalar_from_fr* = blst_scalar_from_fr
  ec_fr_add* = blst_fr_add
  ec_p1_on_curve* = blst_p1_on_curve
  ec_keygen* = blscurve.keyGen

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

func ec_verify*[T: byte|char](
       publicKey: PublicKey,
       message: openarray[T],
       signature: Signature) : bool =
  verify(publicKey, message, signature)