# Simple utils for controlling perf tracing through fifos.
# After creating ack and control fifos with mkfifo, you can use this with:
#
# perf record -g \
#     --delay -1 \
#     --control fifo:./perf-ctl,./perf-ack \
#     --call-graph dwarf \
#     -F 99 \
#     -o perf.data -- [command]

import std/strformat
import std/strutils

import pkg/questionable/results

type Perf* = object
  ctl_file: File
  ack_file: File

proc attach*(Perf: type, ctl_fifo: string, ack_fifo: string): ?!Perf =
  var perf: Perf
  if not open(perf.ctl_file, ctl_fifo, fmWrite):
    return failure("Failed to open ctl fifo")
  if not open(perf.ack_file, ack_fifo, fmRead):
    return failure("Failed to open ack fifo")

  success(perf)

proc detach*(self: Perf) =
  self.ctl_file.close()
  self.ack_file.close()

proc send*(self: Perf, cmd: string): ?!void =
  self.ctl_file.write(cmd)
  self.ctl_file.flushFile()

  let response = self.ack_file.readLine()
  # Ideally equality should work, but in practice we get some garbage
  # characters sometimes.
  if not ("ack" in response):
    return failure(&"Error {response} received from perf")

  success()

proc perfOn*(self: Perf): ?!void =
  send(self, "enable")

proc perfOff*(self: Perf): ?!void =
  send(self, "disable")
