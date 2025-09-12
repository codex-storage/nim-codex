/**
* libcodex.h - C Interface for Example Library
*
* This header provides the public API for libcodex
*
* To see the auto-generated header by Nim, run `make libcodex` from the
* repository root. The generated file will be created at:
* nimcache/release/libcodex/libcodex.h
*/

#ifndef __libcodex__
#define __libcodex__

#include <stddef.h>
#include <stdint.h>

// The possible returned values for the functions that return int
#define RET_OK                0
#define RET_ERR               1
#define RET_MISSING_CALLBACK  2

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*CodexCallback) (int callerRet, const char* msg, size_t len, void* userData);

void* codex_new(
             const char* configJson,
             CodexCallback callback,
             void* userData);

int codex_version(
                void* ctx,
                CodexCallback callback,
                void* userData);

int codex_revision(
                void* ctx,
                CodexCallback callback,
                void* userData);

int codex_start(void* ctx,
               CodexCallback callback,
               void* userData);

int codex_stop(void* ctx,
              CodexCallback callback,
              void* userData);

// Destroys an instance of a codex node created with codex_new
int codex_destroy(void* ctx,
                  CodexCallback callback,
                 void* userData);

void codex_set_event_callback(void* ctx,
                             CodexCallback callback,
                             void* userData);

#ifdef __cplusplus
}
#endif

#endif /* __libcodex__ */