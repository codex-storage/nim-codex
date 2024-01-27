# ## Nim-Codex
# ## Copyright (c) 2024 Status Research & Development GmbH
# ## Licensed under either of
# ##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
# ##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# ## at your option.
# ## This file may not be copied, modified, or distributed except according to
# ## those terms.
# ##

# import pkg/chronos
# import pkg/circomcompat
# import pkg/poseidon2
# import pkg/questionable/results

# import ../../merkletree

# import ./backends
# import ../types

# type
#   Prover*[HashT, ProofT, BackendT] = ref object of RootObj
#     backend: BackendT

#   AnyProof* = Proof
#   AnyHash* = Poseidon2Hash
#   AnyProverBacked* = CircomCompat
#   AnyProver* = Prover[AnyHash, AnyProof, AnyProverBacked]

# proc prove*(
#   self: AnyProver,
#   input: ProofInput[AnyHash]): Future[?!AnyProof] {.async.} =
#   ## Prove a statement using backend.
#   ## Returns a future that resolves to a proof.

#   ## TODO: implement
#   # discard self.backend.prove(input)

# proc verify*(
#   self: AnyProver,
#   proof: AnyProof): Future[?!bool] {.async.} =
#   ## Prove a statement using backend.
#   ## Returns a future that resolves to a proof.

#   ## TODO: implement
#   # discard self.backend.verify(proof)
