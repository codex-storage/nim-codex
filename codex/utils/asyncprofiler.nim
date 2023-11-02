import ../conf

when chronosFuturesInstrumentation:
  import ./asyncprofiler/asyncprofiler
  import ./asyncprofiler/utils
  export asyncprofiler, utils
