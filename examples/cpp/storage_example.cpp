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

// -----------------------------------------------------------------------------
// C++-friendly response helper.
// Mirrors the pattern from tests/cbindings/storage.c but uses modern C++.
// The C callback receives a pointer to an instance of this class as userData.
// -----------------------------------------------------------------------------
class StorageResponse {
public:
    StorageResponse() = default;

    // Not copyable (owns synchronization primitives)
    StorageResponse(const StorageResponse&) = delete;
    StorageResponse& operator=(const StorageResponse&) = delete;

    // Called from the C callback (runs on the libstorage worker thread).
    // We copy the data here so the main thread can safely read it later.
    void setResult(int callerRet, const char* msg, size_t len) {
        std::lock_guard<std::mutex> lock(mtx_);

        if (callerRet == RET_PROGRESS) {
            progressCount_ += 1;
            if (msg && len > 0) {
                lastProgress_.assign(msg, len);
            } else {
                lastProgress_.clear();
            }
            return;
        }

        if (msg && len > 0) {
            result_.assign(msg, len);
        } else {
            result_.clear();
        }
        status_ = callerRet;
        done_ = true;
        cv_.notify_one();
    }

    // Block until the operation completes or timeout.
    // Returns true if we got a terminal response (RET_OK or RET_ERR).
    bool wait(std::chrono::milliseconds timeout = std::chrono::seconds(60)) {
        std::unique_lock<std::mutex> lock(mtx_);
        return cv_.wait_for(lock, timeout, [this] { return done_; });
    }

    int status() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return status_;
    }

    // Returns the payload (JSON for most info calls, error text on error).
    std::string data() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return result_;
    }

    bool isDone() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return done_;
    }

    size_t progressCount() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return progressCount_;
    }

    std::string lastProgress() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return lastProgress_;
    }

private:
    mutable std::mutex mtx_;
    std::condition_variable cv_;
    bool done_ = false;
    int status_ = -1;
    std::string result_;
    size_t progressCount_ = 0;
    std::string lastProgress_;
};

// -----------------------------------------------------------------------------
// The single C callback that the library will invoke for every async operation.
// We store the caller's StorageResponse* in userData.
// This runs on the internal worker thread — keep it fast and non-blocking.
// -----------------------------------------------------------------------------
static void cCallback(int callerRet, const char* msg, size_t len, void* userData) {
    if (auto* resp = static_cast<StorageResponse*>(userData)) {
        resp->setResult(callerRet, msg, len);
    }
}

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------
static bool isOk(int ret) {
    return ret == RET_OK;
}

static void printSection(const std::string& title) {
    std::cout << "\n=== " << title << " ===\n";
}

static void printJsonExcerpt(const std::string& json, size_t maxLen = 300) {
    if (json.empty()) {
        std::cout << "(empty)\n";
        return;
    }
    if (json.size() <= maxLen) {
        std::cout << json << "\n";
    } else {
        std::cout << json.substr(0, maxLen) << "...\n";
    }
}

// -----------------------------------------------------------------------------
// main - demonstrates a typical C++ client usage pattern
// -----------------------------------------------------------------------------
int main() {
    // 1. Initialize the Nim runtime. Must be done once per process.
    libstorageNimMain();

    printSection("Creating storage node");

    // Use a dedicated data directory for this example.
    const char* configJson =
        "{\"log-level\":\"INFO\","
        "\"data-dir\":\"./cpp-example-data\","
        "\"metrics\":false}";

    StorageResponse newResp;
    void* ctx = storage_new(configJson, cCallback, &newResp);

    if (!ctx) {
        std::cerr << "storage_new returned null context\n";
        return 1;
    }

    if (!newResp.wait()) {
        std::cerr << "Timed out waiting for storage_new\n";
        return 1;
    }

    if (!isOk(newResp.status())) {
        std::cerr << "Failed to create node: " << newResp.data() << "\n";
        return 1;
    }

    std::cout << "Node context created successfully.\n";

    // 2. Start the node (async)
    printSection("Starting node");

    StorageResponse startResp;
    if (!isOk(storage_start(ctx, cCallback, &startResp))) {
        std::cerr << "storage_start dispatch failed\n";
        storage_destroy(ctx);
        return 1;
    }

    if (!startResp.wait()) {
        std::cerr << "Timed out waiting for start\n";
        storage_destroy(ctx);
        return 1;
    }

    if (!isOk(startResp.status())) {
        std::cerr << "Start failed: " << startResp.data() << "\n";
        storage_destroy(ctx);
        return 1;
    }

    std::cout << "Node started.\n";

    // 3. Synchronous calls (no callback needed)
    printSection("Version / Revision (synchronous)");

    char* ver = storage_version(ctx);
    if (ver) {
        std::cout << "Version: " << ver << "\n";
        std::free(ver);
    }

    char* rev = storage_revision(ctx);
    if (rev) {
        std::cout << "Revision: " << rev << "\n";
        std::free(rev);
    }

    // 4. Async info queries (very common pattern)
    printSection("Repository (data-dir)");

    StorageResponse repoResp;
    if (!isOk(storage_repo(ctx, cCallback, &repoResp))) {
        std::cerr << "storage_repo dispatch failed\n";
    } else if (repoResp.wait() && isOk(repoResp.status())) {
        std::cout << "Repo: " << repoResp.data() << "\n";
    } else {
        std::cerr << "Failed to get repo: " << repoResp.data() << "\n";
    }

    printSection("Peer ID");

    StorageResponse peerResp;
    if (!isOk(storage_peer_id(ctx, cCallback, &peerResp))) {
        std::cerr << "storage_peer_id dispatch failed\n";
    } else if (peerResp.wait() && isOk(peerResp.status())) {
        std::cout << "PeerId: " << peerResp.data() << "\n";
    } else {
        std::cerr << "Failed to get peer id: " << peerResp.data() << "\n";
    }

    printSection("Metrics (storage_get_metrics)");

    StorageResponse metricsResp;
    if (!isOk(storage_get_metrics(ctx, cCallback, &metricsResp))) {
        std::cerr << "storage_get_metrics dispatch failed\n";
    } else if (metricsResp.wait() && isOk(metricsResp.status())) {
        std::cout << "Metrics JSON excerpt:\n";
        printJsonExcerpt(metricsResp.data());
        // A very basic sanity check that we got something useful
        if (metricsResp.data().find("libp2p_") == std::string::npos) {
            std::cout << "(Note: did not see a libp2p metric in the response)\n";
        }
    } else {
        std::cerr << "Failed to get metrics: " << metricsResp.data() << "\n";
    }

    // 5. Clean shutdown sequence (stop + close + destroy)
    printSection("Stopping node");

    StorageResponse stopResp;
    if (isOk(storage_stop(ctx, cCallback, &stopResp))) {
        stopResp.wait();
    }

    printSection("Closing node");

    StorageResponse closeResp;
    if (isOk(storage_close(ctx, cCallback, &closeResp))) {
        closeResp.wait();
    }

    printSection("Destroying node");

    // storage_destroy is synchronous and does not use a callback.
    if (storage_destroy(ctx) != RET_OK) {
        std::cerr << "storage_destroy reported an error\n";
    } else {
        std::cout << "Node destroyed.\n";
    }

    printSection("Done");
    std::cout << "Example finished successfully.\n";
    return 0;
}
