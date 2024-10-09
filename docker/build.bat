docker build --build-arg MAKE_PARALLEL=4 --build-arg NIMFLAGS="-d:disableMarchNative -d:codex_enable_api_debug_peers=true -d:codex_enable_proof_failures=true -d:codex_use_hardhat=false -d:codex_enable_log_counter=true -d:verify_circuit=true" --build-arg NAT_IP_AUTO=true -t thatbenbierens/nim-codex:prover4 -f codex.Dockerfile .. 
docker push thatbenbierens/nim-codex:prover4

