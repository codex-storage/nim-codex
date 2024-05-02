
# Benchmark Runner

Modify `runAllBenchmarks` proc in `run_benchmarks.nim` to the desired parameters and variations.

Then run it:

```sh
nim c -r run_benchmarks
```

By default all circuit files for each combinations of circuit args will be generated in a unique folder named like:
    nim-codex/benchmarks/circuit_bench_depth32_maxslots256_cellsize2048_blocksize65536_nsamples9_entropy1234567_seed12345_nslots11_ncells512_index3


You can modify the `CircuitArgs` and `CircuitEnv` objects in `runAllBenchMarks` to suite your needs. See `create_circuits.nim` for their definition.

By it runs all commands relative to the `nim-codex` repo. This simplifies finding the correct circuit includes paths, etc. `CircuitEnv` sets all of this.
