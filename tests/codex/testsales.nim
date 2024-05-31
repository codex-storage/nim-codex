# TODO:
# This test file is disabled while the race-condition in
# preparing.nim is being solved.
# https://github.com/codex-storage/nim-codex/pull/816
# import ./sales/testsales

import ./sales/teststates
import ./sales/testreservations
import ./sales/testslotqueue
import ./sales/testsalesagent

{.warning[UnusedImport]: off.}
