## Nim-POS
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/protobuf_serialization
import pkg/stew/results
import pkg/stew/objects
import pkg/blscurve
import pkg/blscurve/blst/blst_abi

import_proto3 "por.proto"

export TauZeroMessage, TauMessage, ProofMessage, PoRMessage, PoREnvelope

import ../por

func toMessage*(self: Proof): ProofMessage =
  var
    message = ProofMessage()
    sigma: array[48, byte]

  for mu in self.mu:
    var
      serialized: array[32, byte]
    blst_bendian_from_scalar(serialized, mu)
    message.mu.add(toSeq(serialized))

  blst_p1_compress(sigma, self.sigma)
  message.sigma = toSeq(sigma)

  message

func fromMessage*(self: ProofMessage): Result[Proof, string] =
  var
    proof = Proof()
    sigmaAffine: blst_p1_affine

  if blst_p1_uncompress(sigmaAffine, toArray(48, self.sigma)) != BLST_SUCCESS:
    return err("Unable to decompress sigma")

  blst_p1_from_affine(proof.sigma, sigmaAffine)

  for mu in self.mu:
    var
      muScalar: blst_scalar
    blst_scalar_from_bendian(muScalar, toArray(32, mu))

    proof.mu.add(muScalar)

  ok(proof)

func toMessage*(self: TauZero, compress = false): TauZeroMessage =
  var
    message = TauZeroMessage(
      name: toSeq(self.name),
      n: self.n)

  for u in self.u:
    var
      serialized: array[48, byte]

    # serialized and compresses the points
    blst_p1_compress(serialized, u)
    message.u.add(toSeq(serialized))

  message

func fromMessage*(self: TauZeroMessage): Result[TauZero, string] =
  var
    tauZero: TauZero

  tauZero.name = toArray(512, self.name)
  tauZero.n = self.n

  for u in self.u:
    var
      uuAffine: blst_p1_affine
      uu: blst_p1

    if blst_p1_uncompress(uuAffine, toArray(48, u)) != BLST_SUCCESS:
      return err("Unable to decompress u")

    blst_p1_from_affine(uu, uuAffine)
    tauZero.u.add(uu)

  ok(tauZero)

func toMessage*(self: Tau): TauMessage =
  TauMessage(t: self.t.toMessage(), signature: toSeq(self.signature))

func fromMessage*(self: TauMessage): Result[Tau, string] =
  var
    message = Tau(
      t: ? self.t.fromMessage(),
      signature: toArray(96, self.signature))

  ok(message)

func toMessage*(self: por.PublicKey): PubKeyMessage =
  var
    message = PubKeyMessage(signkey: toSeq(self.signkey.exportRaw()))
    key: array[96, byte]

  blst_p2_compress(key, self.key)
  message.key = toSeq(key)

  message

func fromMessage*(self: PubKeyMessage): Result[por.PublicKey, string] =
  var
    spk: por.PublicKey
    keyAffine: blst_p2_affine

  if not spk.signkey.fromBytes(self.signkey.toOpenArray(0, 47)):
    return err("Unable to deserialize public key!")

  if blst_p2_uncompress(keyAffine, toArray(96, self.key)) != BLST_SUCCESS:
    return err("Unable to decompress key!")

  blst_p2_from_affine(spk.key, keyAffine)

  ok(spk)

func toMessage*(self: PoR): PoRMessage =
  var
    message = PoRMessage(
      tau: self.tau.toMessage(),
      spk: self.spk.toMessage())

  for sigma in self.authenticators:
    var
      compressed: array[48, byte]

    blst_p1_compress(compressed, sigma)
    message.authenticators.add(toSeq(compressed))

  message

func fromMessage*(self: PoRMessage): Result[PoR, string] =
  var
    por = PoR(
      tau: ? self.tau.fromMessage(),
      spk: ? self.spk.fromMessage())

  for sigma in self.authenticators:
    var
      sigmaAffine: blst_p1_affine
      authenticator: blst_p1

    if blst_p1_uncompress(sigmaAffine, toArray(48, sigma)) != BLST_SUCCESS:
      return err("Unable to decompress sigma")

    blst_p1_from_affine(authenticator, sigmaAffine)
    por.authenticators.add(authenticator)

  return ok(por)
