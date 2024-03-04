import os
import zip/zipfiles
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ./backends

type
  BackendUtils* = ref object of RootObj

method initializeCircomBackend*(
  self: BackendUtils,
  r1csFile: string,
  wasmFile: string,
  zKeyFile: string
): AnyBackend {.base.} =
  CircomCompat.init(r1csFile, wasmFile, zKeyFile)

method downloadFile*(
  self: BackendUtils,
  url: string,
  filepath: string
): ?!void {.base.} =
  try:
    # Nim's default webclient does not support SSL on all platforms.
    # Not without shipping additional binaries and cert-files... :(
    # So we're using curl for now.
    var rc = execShellCmd("curl -o " & filepath & " " & url)
    if not rc == 0:
      return failure("Download of '" & url & "' failed with return code: " & $rc)
  except Exception as exc:
    return failure(exc.msg)
  success()

method unzipFile*(
  self: BackendUtils,
  zipFile: string,
  outputDir: string): ?!void {.base.} =
  var z: ZipArchive
  if not z.open(zipFile):
    return failure("Unable to open zip file: " & zipFile)
  z.extractAll(outputDir)
  success()
