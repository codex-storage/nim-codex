import pkg/chronos
import pkg/questionable
import pkg/confutils/defs

import ../../conf
import ./backends

proc initializeFromConfig(
  config: CodexConf): ?!AnyBackend =

  # check provided files exist
  # initialize backend with files
  # or failure

  success(CircomCompat.init($config.circomR1cs, $config.circomWasm, $config.circomZkey))

proc initializeFromCeremonyFiles(): ?!AnyBackend =

  # initialize from previously-downloaded files if they exist
  echo "todo"
  failure("todo")

proc initializeFromCeremonyUrl(
  proofCeremonyUrl: ?string): Future[?!AnyBackend] {.async.} =

  # download the ceremony url
  # unzip it

  without backend =? initializeFromCeremonyFiles(), err:
    return failure(err)
  return success(backend)

proc initializeBackend*(
  config: CodexConf,
  proofCeremonyUrl: ?string): Future[?!AnyBackend] {.async.} =

  without backend =? initializeFromConfig(config), cliErr:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    without backend =? initializeFromCeremonyFiles(), localErr:
      info "Could not initialize prover backend from local files...", msg = localErr.msg
      without backend =? (await initializeFromCeremonyUrl(proofCeremonyUrl)), urlErr:
        warn "Could not initialize prover backend from ceremony url...", msg = urlErr.msg
        return failure(urlErr)
  return success(backend)
