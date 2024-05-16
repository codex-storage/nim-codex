
import std/sequtils

import pkg/taskpools
import pkg/taskpools/flowvars
import pkg/chronos
import pkg/chronos/threadsync
import pkg/questionable/results


const
  CompletitionTimeout = 1.seconds # Maximum await time for completition after receiving a signal
  CompletitionRetryDelay = 10.millis

type
  EncoderBackendPtr = ptr EncoderBackend

  # Args objects are missing seq[seq[byte]] field, to avoid unnecessary data copy
  EncodeTaskArgs = object
    signal: ThreadSignalPtr
    backend: EncoderBackendPtr
    blockSize: int
    ecM: int
