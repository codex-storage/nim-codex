import ./slots/builder
import ./slots/sampler
import ./merkletree

export builder, sampler

type
  Poseidon2Builder* = SlotsBuilder[Poseidon2Tree, Poseidon2Hash]
  Poseidon2Sampler* = DataSampler[Poseidon2Tree, Poseidon2Hash, Poseidon2Proof]
