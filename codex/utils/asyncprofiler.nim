import ../conf

when chronosFuturesInstrumentation:
  import ./asyncprofiler/asyncprofiler
  import ./asyncprofiler/serialization
  export asyncprofiler, serialization
