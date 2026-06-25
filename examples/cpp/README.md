# Using Logos Storage from C and C++

This directory contains **ready-to-build C++ examples** showing how to use the Logos Storage C bindings from a C++ application.

Everything here is self-contained under `examples/cpp/`. No existing files in the repository were modified.

## Quick Start

```bash
# From the repository root, make sure the C library is built
make libstorage

# Go to the C++ example
cd examples/cpp

# Build
make

# Run (the library is loaded from the build directory)
LD_LIBRARY_PATH=../../build ./storage_example
```

Or simply:

```bash
make run   # (from examples/cpp)
```

## High-Level Mental Model

The Logos Storage library exposes a **stable C ABI**. All heavy work happens inside Nim on a dedicated worker thread.

Key concepts:

- **`void* ctx`** — Opaque handle to a `StorageContext`. You get it from `storage_new()` and pass it to every other call. Think of it as "the node".
- **Most APIs are asynchronous** — You call a function (e.g. `storage_start`, `storage_get_metrics`). It returns immediately with a dispatch status (`RET_OK`, `RET_ERR`, ...). The real result arrives later via your `StorageCallback`.
- **`StorageCallback`** — A C function pointer with this signature:

  ```c
  typedef void (*StorageCallback)(int callerRet, const char *msg, size_t len, void *userData);
  ```

  - `callerRet` is one of `RET_OK`, `RET_ERR`, `RET_PROGRESS`, `RET_MISSING_CALLBACK`.
  - `msg` / `len` contain the payload (usually JSON) or an error string.
  - `userData` is whatever pointer **you** passed in — the library just hands it back.

- **Callbacks run on the worker thread** — They must be fast and non-blocking. Do not do heavy work, I/O, or call back into libstorage from inside the callback.
- **`userData` is caller-owned** — You decide what it points to (a struct, a C++ object, a promise, etc.). The library never frees it.

## Lifecycle (the only correct order)

```text
storage_new(...)                 -> gives you ctx (result comes via callback)
    |
    v
storage_start(ctx, ...)          -> start the node (async)
    |
    v
... do useful work (repo, peer_id, get_metrics, upload, download, etc.) ...
    |
    v
storage_stop(ctx, ...)
storage_close(ctx, ...)
storage_destroy(ctx)             -> synchronous, no callback needed
```

You can `start` / `stop` the same context multiple times. Always `stop` + `close` before `destroy`.

## Return Codes

| Constant           | Value | Meaning |
|--------------------|-------|---------|
| `RET_OK`           | 0     | Operation dispatched successfully (or completed for sync calls) |
| `RET_ERR`          | 1     | Immediate failure or error reported via callback |
| `RET_MISSING_CALLBACK` | 2 | You forgot to pass a callback for an async function |
| `RET_PROGRESS`     | 3     | Intermediate progress (used by upload/download streaming) |

Only `RET_OK` and `RET_ERR` are terminal for normal calls.

## Synchronous vs Asynchronous Calls

**Synchronous (no callback, result returned directly):**

- `storage_version(ctx)` → `char*` (you must `free()` it)
- `storage_revision(ctx)` → `char*` (you must `free()` it)
- `storage_destroy(ctx)`

**Asynchronous (result via callback):**

Everything else: `storage_start`, `storage_stop`, `storage_repo`, `storage_peer_id`, `storage_get_metrics`, `storage_list`, `storage_space`, upload/download APIs, etc.

## How to Wait for an Async Result from C++

The classic C pattern (see `tests/cbindings/storage.c`) uses a `pthread_mutex` + `pthread_cond_t` struct called `Resp`.

In C++ we do the modern equivalent:

```cpp
class StorageResponse {
    // mutex + condition_variable
    // setResult(...) called from the C callback
    // wait(timeout) on the calling thread
};
```

See `storage_example.cpp` for a clean, production-style implementation (`StorageResponse` + `cCallback`).

Typical call pattern:

```cpp
StorageResponse resp;
if (storage_repo(ctx, cCallback, &resp) != RET_OK) { /* dispatch failed */ }

if (!resp.wait(std::chrono::seconds(30)) || resp.status() != RET_OK) {
    // handle error
}
std::cout << "Repo: " << resp.data() << "\n";
```

## Important Rules & Gotchas (especially when coming from other languages)

1. **Call `libstorageNimMain()` exactly once** before any other function. This initializes the Nim runtime.
2. **Free strings returned by `storage_version` / `storage_revision`** with `std::free` (or `free`).
3. **Progress callbacks (`RET_PROGRESS`)** are *not* terminal. Only mark completion when you receive `RET_OK` or `RET_ERR`.
4. **The worker thread owns the callback invocation.** Any objects you touch from the callback must be thread-safe or protected.
5. **JSON is the lingua franca.** Most responses (`debug`, `metrics`, `list`, manifests, etc.) are JSON strings.
6. **Metrics are currently process-global.** `storage_get_metrics` returns data from the single `defaultRegistry`. If you create multiple `ctx` instances in the same process they share the same metric set.
7. **Config is a JSON string.** See the main `openapi.yaml` or existing tests for the schema. Minimal useful example:

   ```json
   {"log-level":"WARN", "data-dir":"./my-data"}
   ```

8. **Build & runtime linking.** You must link against `libstorage.so` (or the static `.a`) and make sure the dynamic linker can find it at runtime (`LD_LIBRARY_PATH`, rpath, or install it in a standard location).

## Detailed Code Walkthrough

This section walks through `storage_example.cpp` in detail. The goal is to make it easy to understand exactly how a C++ application interacts with the C API, especially if you switch languages frequently.

The full source is in `storage_example.cpp`. We will go through it section by section.

### 1. Includes and Nim Runtime Declaration

```cpp
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>

extern "C" {
#include "libstorage.h"

// Forward declaration of the Nim runtime initializer.
// Must be called once before any other libstorage call.
extern void libstorageNimMain(void);
}
```

**Key points:**
- We include the C header inside an `extern "C"` block so the C++ compiler knows the functions have C linkage.
- `libstorageNimMain()` is declared here because it is not part of the public header (it is generated by Nim). It **must** be called exactly once before using any other API. It initializes the Nim garbage collector and runtime.

### 2. The `StorageResponse` Class — Bridging the Callback Model

This is the most important piece for comfortable C++ usage.

```cpp
class StorageResponse {
public:
    StorageResponse() = default;

    // Not copyable (owns synchronization primitives)
    StorageResponse(const StorageResponse&) = delete;
    StorageResponse& operator=(const StorageResponse&) = delete;

    // Called from the C callback (runs on the libstorage worker thread).
    void setResult(int callerRet, const char* msg, size_t len) {
        std::lock_guard<std::mutex> lock(mtx_);

        if (msg && len > 0) {
            result_.assign(msg, len);
        } else {
            result_.clear();
        }
        status_ = callerRet;
        done_ = true;
        cv_.notify_one();
    }

    bool wait(std::chrono::milliseconds timeout = std::chrono::seconds(60)) {
        std::unique_lock<std::mutex> lock(mtx_);
        return cv_.wait_for(lock, timeout, [this] { return done_; });
    }

    int status() const { ... }
    std::string data() const { ... }
    bool isDone() const { ... }

private:
    mutable std::mutex mtx_;
    std::condition_variable cv_;
    bool done_ = false;
    int status_ = -1;
    std::string result_;
};
```

**Why this design?**

- The C API is callback-based. The library calls your `StorageCallback` later, possibly from another thread.
- We turn the fire-and-forget + callback model into a simple "call → wait → read result" pattern that feels natural in C++.
- `setResult` is called from the worker thread → we protect everything with a mutex.
- We **copy** the message into `std::string result_` inside `setResult`. This is important because the `msg` pointer is only valid for the duration of the callback.
- Deleted copy constructor/assignment: the class owns a `std::mutex` and `std::condition_variable`, which are not copyable.
- `wait()` uses `wait_for` with a timeout as a safety net (the C test harness uses a similar retry-based wait).

This class is the C++ equivalent of the `Resp` struct + `alloc_resp`/`wait_resp`/`is_resp_ok` functions in `tests/cbindings/storage.c`.

### 3. The C Callback Adapter

```cpp
static void cCallback(int callerRet, const char* msg, size_t len, void* userData) {
    if (auto* resp = static_cast<StorageResponse*>(userData)) {
        resp->setResult(callerRet, msg, len);
    }
}
```

This is the actual function we register with every async call.

- It has the exact signature required by `StorageCallback`.
- It casts `userData` back to `StorageResponse*` (the pointer we passed when calling `storage_xxx`).
- It is deliberately tiny — remember the rule: **callbacks must be fast and non-blocking**.

### 4. Small Utility Functions

```cpp
static bool isOk(int ret) { return ret == RET_OK; }

static void printSection(const std::string& title) { ... }

static void printJsonExcerpt(const std::string& json, size_t maxLen = 300) { ... }
```

These are just for readability. `isOk` makes the main logic easier to follow. The print helpers keep the output clean during the example run.

### 5. `main()` — Step by Step

#### Step 5.1: Runtime initialization and node creation

```cpp
int main() {
    libstorageNimMain();   // Required first step

    const char* configJson = "{\"log-level\":\"INFO\","
                             "\"data-dir\":\"./cpp-example-data\","
                             "\"metrics\":false}";

    StorageResponse newResp;
    void* ctx = storage_new(configJson, cCallback, &newResp);

    if (!ctx) { /* handle immediate failure */ }

    if (!newResp.wait()) { /* timeout */ }
    if (!isOk(newResp.status())) { /* creation failed */ }
```

Important observations:
- `storage_new` returns the context pointer **synchronously**, but the actual initialization result comes through the callback (just like in the C test).
- We pass `&newResp` as `userData`. The library will call `cCallback(..., &newResp)`.
- Always check the immediate return value **and** the result that arrives via the callback.

#### Step 5.2: Starting the node

```cpp
StorageResponse startResp;
if (!isOk(storage_start(ctx, cCallback, &startResp))) {
    // dispatch failed immediately
    storage_destroy(ctx);
    return 1;
}
if (!startResp.wait() || !isOk(startResp.status())) {
    // start failed asynchronously
}
```

Note how we create a **fresh** `StorageResponse` for every async operation. This is the recommended pattern.

#### Step 5.3: Synchronous calls

```cpp
char* ver = storage_version(ctx);
if (ver) {
    std::cout << "Version: " << ver << "\n";
    std::free(ver);           // Important: caller must free
}
```

Only a few functions are synchronous:
- `storage_version`
- `storage_revision`
- `storage_destroy`

Everything else goes through the callback mechanism.

#### Step 5.4: Async information queries (the common pattern)

```cpp
// Repository
StorageResponse repoResp;
if (!isOk(storage_repo(ctx, cCallback, &repoResp))) {
    // dispatch error
} else if (repoResp.wait() && isOk(repoResp.status())) {
    std::cout << "Repo: " << repoResp.data() << "\n";
}

// Same pattern for peer_id and metrics
StorageResponse metricsResp;
storage_get_metrics(ctx, cCallback, &metricsResp);
metricsResp.wait();
printJsonExcerpt(metricsResp.data());
```

This is the core usage pattern you will repeat for almost every API:
1. Create a `StorageResponse` on the stack.
2. Call the `storage_*` function, passing `cCallback` and `&yourResp`.
3. Check the immediate return code.
4. Call `.wait()`.
5. Check `.status()` and read `.data()`.

#### Step 5.5: Metrics specifically

The `storage_get_metrics` call returns JSON in the Logos openmetrics format (with `name`, `type`, `help`, `value`, `labels`). The example prints an excerpt and does a simple sanity check for known metrics.

#### Step 5.6: Shutdown sequence

```cpp
StorageResponse stopResp;
if (isOk(storage_stop(ctx, cCallback, &stopResp))) {
    stopResp.wait();
}

StorageResponse closeResp;
if (isOk(storage_close(ctx, cCallback, &closeResp))) {
    closeResp.wait();
}

if (storage_destroy(ctx) != RET_OK) { ... }
```

Order matters:
- `stop` (async)
- `close` (async)
- `destroy` (synchronous — no callback)

You should always stop + close before destroy.

### Design Observations & Lessons

- **One `StorageResponse` per operation** — Reusing the same object for multiple calls is possible but error-prone (you would need to reset `done_`). Creating a new one per call is clearer and safer.
- **No RAII wrapper for `ctx`** in this example — We do manual lifecycle to keep the example simple and explicit. In real code you would probably wrap `ctx` in a class that calls `stop`/`close`/`destroy` in its destructor.
- **Error handling is deliberately repetitive** — This mirrors the reality of the C API. In a larger project you would likely build a small wrapper layer on top of `StorageResponse`.
- **Threading model is hidden but important** — Your main thread mostly blocks on condition variables. The real work and the callbacks happen on the libstorage worker thread.
- **Memory ownership** — Strings returned by `storage_version`/`storage_revision` must be freed by you. Data delivered via callbacks is copied by `StorageResponse`, so you don't have to worry about the original buffer lifetime.

This pattern (small response object + single C callback trampoline + per-call instances) is very close to what the original C test harness does, just expressed in idiomatic C++.

## Illustrative Snippets (Quick Reference)

(kept for quick copy-paste)

### Creating a node and starting it

```cpp
libstorageNimMain();

const char* cfg = R"({"log-level":"INFO","data-dir":"./data"})";

StorageResponse initResp;
void* ctx = storage_new(cfg, cCallback, &initResp);
initResp.wait();

StorageResponse startResp;
storage_start(ctx, cCallback, &startResp);
startResp.wait();
```

### Getting metrics

```cpp
StorageResponse m;
storage_get_metrics(ctx, cCallback, &m);
m.wait();

if (m.status() == RET_OK) {
    // m.data() contains JSON with name, type, help, value, labels
}
```

### Clean shutdown

```cpp
storage_stop(ctx, cCallback, &stopResp);   stopResp.wait();
storage_close(ctx, cCallback, &closeResp); closeResp.wait();
storage_destroy(ctx);   // synchronous
```

## Directory Contents

- `storage_example.cpp` — Full working C++ program with `StorageResponse` helper
- `Makefile` — Simple, copy-paste friendly build system
- `README.md` — This file (mental model + detailed code walkthrough)

## Further Reading (from the main tree)

- `library/libstorage.h` — The authoritative C header (all signatures and comments).
- `tests/cbindings/storage.c` — The reference C implementation. This is the best place to see the exact waiting + callback pattern the C++ code is modeled after.
- `library/storage_context.nim` and `library/storage_thread_requests/storage_thread_request.nim` — If you want to understand the worker thread and "callbacks run on the worker thread" rule.

## Notes for Polyglot Developers

If you are coming from other languages:

- The binding is intentionally thin. Most complexity lives in Nim.
- The async + callback + userData model is very common in C libraries that have to cross thread boundaries (similar to many libuv-style or Java JNI callback patterns).
- For production use you will almost certainly want a small C++ wrapper class that owns the `ctx` and provides RAII + futures or coroutines.

Happy hacking!
