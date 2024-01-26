import ./slots/builder
import ./slots/sampler
import ./slots/proofs
import ./merkletree

export builder, sampler, proofs

type
  Poseidon2Builder* = SlotsBuilder[Poseidon2Tree, Poseidon2Hash]
  Poseidon2Sampler* = DataSampler[Poseidon2Tree, Poseidon2Hash]
