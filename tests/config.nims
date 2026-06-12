--path:
  ".."
--threads:
  on
--tlsEmulation:
  off

when not defined(chronicles_log_level):
  --define:
    "chronicles_log_level:TRACE" # compile trace log statements
  --define:
    "chronicles_sinks:textlines[dynamic]" # allow logs to be filtered at runtime
  --"import":
    "logging_config" # ensure that logging is ignored at runtime
