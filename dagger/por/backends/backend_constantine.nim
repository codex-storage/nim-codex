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

import
  constantine,
  # constantine/platforms/abstractions,
  constantine/math/arithmetic,
  # constantine/math/extension_fields,
  # constantine/math/config/curves,
  constantine/math/elliptic/[ec_shortweierstrass_affine, ec_shortweierstrass_projective],
  constantine/math/curves/[zoo_subgroups, zoo_pairings, zoo_generators],
  # constantine/math/pairing/cyclotomic_subgroup,
  # constantine/math/io/io_extfields,
  constantine/math/io/io_bigints,
  # constantine/math/config/[curves_declaration, type_ff],
  constantine/math/config/type_ff,
  constantine/blssig_pop_on_bls12381_g2,
  constantine/hash_to_curve/hash_to_curve,
  constantine/hashes,
  constantine/math/pairings

export hashes
export matchingBigInt
export getNonResidueFp

when defined(debugConstantine):
  export `$`

const C = BLS12_381

type
  ec_SecretKey* = SecretKey
  ec_PublicKey* = PublicKey
  ec_p1* = ECP_ShortW_Jac[Fp2[C], G2]
  ec_p1_affine = ECP_ShortW_Aff[Fp2[C], G2]
  ec_p2* = ECP_ShortW_Jac[Fp[C], G1]
  ec_p2_affine = ECP_ShortW_Aff[Fp[C], G1]
  ec_scalar* = matchingOrderBigInt(C)
  ec_fr* = Fr[C]
  ec_signature* = Signature

let
  EC_G1* = C.getGenerator($G2)
  EC_G2* = C.getGenerator($G1)

func ec_p1_from_affine*(dst: var ec_p1, a: ec_p1_affine) = 
  dst.fromAffine(a)

#let ec_scalar_from_bendian* = unmarshalBE # not exposed
func ec_scalar_from_bendian*(
    s: var ec_scalar,
    b: openArray[byte]) =
  s.unmarshal(b, bigEndian)

#let ec_scalar_fr_check* = blst_scalar_fr_check
func ec_scalar_fr_check*(
    s: ec_scalar) : bool =
  bool(s < C.getCurveOrder())

func ec_p2_from_affine*(dst: var ec_p2, a: ec_p2_affine) = 
  dst.fromAffine(a)
  
func ec_p2_mult*(
    dst: var ec_p2,
    p: ec_p2,
    scalar: ec_scalar,
    nbits: uint) =
  dst = p
  dst.scalarMul(scalar)

func ec_p1_mult*(
    dst: var ec_p1,
    p: ec_p1,
    scalar: ec_scalar,
    nbits: uint) =
  dst = p
  dst.scalarMul(scalar)

func ec_p1_add_or_double*(dst: var ec_p1, a: ec_p1, b: ec_p1) =
  dst.sum(a,b)

# Workaround: using ec_fr makes bindConstant fail, hence Fr[C] type below
func ec_fr_from_scalar*(res: var Fr[C], scalar: ec_scalar) =
  res.fromBig(scalar)

# Workaround: using ec_fr makes bindConstant fail, hence Fr[C] type below
func ec_scalar_from_fr*(res: var ec_scalar, fr: Fr[C]) =
  res = toBig(fr)

func ec_fr_add*(res: var Fr[C], a, b: Fr[C]) =
  sum(res, a, b)

func ec_fr_mul*(res: var Fr[C], a, b: Fr[C]) =
  prod(res, a, b)

func ec_p1_on_curve*(p: ec_p1) : bool =
  var aff : ec_p1_affine
  aff.affine(p)
  (bool) isOnCurve(aff.x, aff.y, G1)

func ec_keygen*(ikm: array[32, byte], pk: var PublicKey, sk: var SecretKey) : bool =
  # TODO: HKDF key generation as in spec (https://tools.ietf.org/html/draft-irtf-cfrg-bls-signature#section-2.3)
  var ikm2 = ikm
  ikm2[0] = 0 # TODO: this is a hack, not secure
  let ok = sk.deserialize_secret_key(ikm2)
  doAssert ok == cttBLS_Success
  let ok2 = pk.derive_public_key(sk)
  doAssert ok2 == cttBLS_Success
  (ok == cttBLS_Success) and (ok2 == cttBLS_Success)

func ec_export_raw*(signature: Signature): array[96, byte] {.inline, noinit.} =
  let ok = result.serialize_signature_compressed(signature)
  doAssert ok == cttBLS_Success

proc ec_sign*[T: byte|char](secretKey: SecretKey, message: openarray[T]): Signature =
  let ok = result.sign(secretKey, message)
  doAssert ok == cttBLS_Success

proc ec_hash_to_g1*(dst: var ec_p1,
                       msg: openArray[byte],
                       domainSepTag: openArray[char],
                       aug: openArray[char]) =
  sha256.hashToCurve(128, dst, aug, msg, domainSepTag) #TODO: fix k

proc verifyPairings*(a1: ec_p1, a2: ec_p2, b1: ec_p1, b2: ec_p2) : bool =
  when C.getEmbeddingDegree() == 12:
    var gt1, gt2 {.noInit.}: Fp12[C]
  else:
    {.error: "Not implemented: signature on k=" & $C.getEmbeddingDegree() & " for curve " & $$C.}

  var a1aff, b1aff {.noInit.}: ec_p1_affine
  var a2aff, b2aff {.noInit.}: ec_p2_affine
  a1aff.affine(a1)
  b1aff.affine(b1)
  a2aff.affine(a2)
  b2aff.affine(b2)
  gt1.pairing(a2aff, a1aff)
  gt2.pairing(b2aff, b1aff)
  return bool(gt1 == gt2)

func ec_from_bytes*(
       dst: var Signature,
       raw: array[96, byte] or array[192, byte]
      ): bool {.inline.} =
  let ok = dst.deserialize_signature_compressed(raw)
  doAssert ok == cttBLS_Success

func ec_verify*(
       publicKey: PublicKey,
       message: openarray[char],
       signature: Signature) : bool =
  publicKey.verify(message, signature) == cttBLS_Success
