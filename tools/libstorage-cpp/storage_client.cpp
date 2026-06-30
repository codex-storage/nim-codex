#include "storage_client.hpp"

#include <cstdlib>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>

extern "C" {
extern void libstorageNimMain(void);
}

namespace {
void ensureNimRuntime() {
    static std::once_flag once;
    std::call_once(once, [] { libstorageNimMain(); });
}

bool isOk(int ret) {
    return ret == RET_OK;
}

std::string takeCString(char* value) {
    if (!value) {
        return {};
    }

    std::string result(value);
    std::free(value);
    return result;
}

void shutdownContextBestEffort(
    void* ctx,
    StorageCallback callback,
    std::chrono::milliseconds timeout) {
    if (!ctx) {
        return;
    }

    auto resp = std::make_unique<StorageResponse>();
    if (storage_shutdown(ctx, callback, resp.get()) != RET_OK) {
        return;
    }

    if (!resp->wait(timeout)) {
        // The callback may still fire after timeout; keep userData alive.
        resp.release();
    }
}
}

void StorageResponse::setResult(int callerRet, const char* msg, size_t len) {
    std::lock_guard<std::mutex> lock(mtx_);

    if (callerRet == RET_PROGRESS) {
        progressCount_ += 1;
        progressBytes_ += len;
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

bool StorageResponse::wait(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mtx_);
    if (timeout.count() == 0) {
        cv_.wait(lock, [this] { return done_; });
        return true;
    }
    return cv_.wait_for(lock, timeout, [this] { return done_; });
}

int StorageResponse::status() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return status_;
}

std::string StorageResponse::data() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return result_;
}

size_t StorageResponse::progressCount() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return progressCount_;
}

size_t StorageResponse::progressBytes() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return progressBytes_;
}

std::string StorageResponse::lastProgress() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return lastProgress_;
}

StorageClient::StorageClient(std::string configJson, std::chrono::milliseconds timeout)
    : timeout_(timeout) {
    ensureNimRuntime();

    auto resp = std::make_unique<StorageResponse>();
    ctx_ = storage_new(configJson.c_str(), callback, resp.get());
    if (!ctx_) {
        throw std::runtime_error("storage_new returned null context");
    }

    if (!resp->wait(timeout_)) {
        resp.release();
        shutdownContextBestEffort(ctx_, callback, timeout_);
        ctx_ = nullptr;
        throw std::runtime_error("storage_new timed out");
    }

    if (!isOk(resp->status())) {
        std::string error = resp->data();
        shutdownContextBestEffort(ctx_, callback, timeout_);
        ctx_ = nullptr;
        throw std::runtime_error("storage_new failed: " + error);
    }
}

StorageClient::~StorageClient() {
    if (!ctx_) {
        return;
    }

    try {
        shutdown();
    } catch (...) {
        // Destructors must not throw; callers should use explicit shutdown for errors.
        ctx_ = nullptr;
    }
}

void StorageClient::start() {
    call("storage_start", [this](StorageCallback cb, void* userData) {
        return storage_start(ctx_, cb, userData);
    });
    started_ = true;
}

void StorageClient::shutdown() {
    if (!ctx_) {
        return;
    }

    auto resp = std::make_unique<StorageResponse>();
    const int dispatchRet = storage_shutdown(ctx_, callback, resp.get());
    if (!isOk(dispatchRet)) {
        throw std::runtime_error("storage_shutdown dispatch failed");
    }

    // After successful dispatch, libstorage owns ctx_ even if waiting fails.
    ctx_ = nullptr;
    started_ = false;

    if (!resp->wait(timeout_)) {
        // After dispatch, libstorage owns ctx_ and may still call back later.
        resp.release();
        throw std::runtime_error("storage_shutdown timed out");
    }

    if (!isOk(resp->status())) {
        throw std::runtime_error("storage_shutdown failed: " + resp->data());
    }
}

std::string StorageClient::version() const {
    return takeCString(storage_version(ctx_));
}

std::string StorageClient::revision() const {
    return takeCString(storage_revision(ctx_));
}

std::string StorageClient::repo() {
    return call("storage_repo", [this](StorageCallback cb, void* userData) {
        return storage_repo(ctx_, cb, userData);
    });
}

std::string StorageClient::peerId() {
    return call("storage_peer_id", [this](StorageCallback cb, void* userData) {
        return storage_peer_id(ctx_, cb, userData);
    });
}

std::string StorageClient::metrics() {
    return call("storage_get_metrics", [this](StorageCallback cb, void* userData) {
        return storage_get_metrics(ctx_, cb, userData);
    });
}

std::string StorageClient::debug() {
    return call("storage_debug", [this](StorageCallback cb, void* userData) {
        return storage_debug(ctx_, cb, userData);
    });
}

std::string StorageClient::spr() {
    return call("storage_spr", [this](StorageCallback cb, void* userData) {
        return storage_spr(ctx_, cb, userData);
    });
}

std::string StorageClient::list() {
    return call("storage_list", [this](StorageCallback cb, void* userData) {
        return storage_list(ctx_, cb, userData);
    });
}

std::string StorageClient::space() {
    return call("storage_space", [this](StorageCallback cb, void* userData) {
        return storage_space(ctx_, cb, userData);
    });
}

std::string StorageClient::manifest(const std::string& cid) {
    return call("storage_download_manifest", [this, &cid](StorageCallback cb, void* userData) {
        return storage_download_manifest(ctx_, cid.c_str(), cb, userData);
    });
}

std::string StorageClient::exists(const std::string& cid) {
    return call("storage_exists", [this, &cid](StorageCallback cb, void* userData) {
        return storage_exists(ctx_, cid.c_str(), cb, userData);
    });
}

std::string StorageClient::deleteContent(const std::string& cid) {
    return call("storage_delete", [this, &cid](StorageCallback cb, void* userData) {
        return storage_delete(ctx_, cid.c_str(), cb, userData);
    });
}

std::string StorageClient::fetch(const std::string& cid) {
    return call("storage_fetch", [this, &cid](StorageCallback cb, void* userData) {
        return storage_fetch(ctx_, cid.c_str(), cb, userData);
    });
}

std::string StorageClient::connect(
    const std::string& peerId,
    const std::vector<std::string>& peerAddresses) {
    std::vector<const char*> addresses;
    addresses.reserve(peerAddresses.size());
    for (const auto& address : peerAddresses) {
        addresses.push_back(address.c_str());
    }

    return call("storage_connect", [this, &peerId, &addresses](StorageCallback cb, void* userData) {
        return storage_connect(ctx_, peerId.c_str(), addresses.data(), addresses.size(), cb, userData);
    });
}

std::string StorageClient::uploadFile(const std::string& filepath, size_t chunkSize) {
    const std::string sessionId = call("storage_upload_init", [this, &filepath, chunkSize](
                                                             StorageCallback cb,
                                                             void* userData) {
        return storage_upload_init(ctx_, filepath.c_str(), chunkSize, cb, userData);
    });

    return call("storage_upload_file", [this, &sessionId](StorageCallback cb, void* userData) {
        return storage_upload_file(ctx_, sessionId.c_str(), cb, userData);
    });
}

std::string StorageClient::downloadFile(
    const std::string& cid,
    const std::string& outputPath,
    size_t chunkSize,
    bool local) {
    call("storage_download_init", [this, &cid, chunkSize, local](StorageCallback cb, void* userData) {
        return storage_download_init(ctx_, cid.c_str(), chunkSize, local, cb, userData);
    });

    return call("storage_download_stream", [this, &cid, &outputPath, chunkSize, local](
                                               StorageCallback cb,
                                               void* userData) {
        return storage_download_stream(
            ctx_, cid.c_str(), chunkSize, local, outputPath.c_str(), cb, userData);
    });
}

size_t StorageClient::streamSink(const std::string& cid, size_t chunkSize, bool local) {
    call("storage_download_init", [this, &cid, chunkSize, local](StorageCallback cb, void* userData) {
        return storage_download_init(ctx_, cid.c_str(), chunkSize, local, cb, userData);
    });

    auto resp = std::make_unique<StorageResponse>();
    const int dispatchRet = storage_download_stream(
        ctx_, cid.c_str(), chunkSize, local, "", callback, resp.get());
    if (!isOk(dispatchRet)) {
        throw std::runtime_error("storage_download_stream dispatch failed");
    }

    if (!resp->wait(timeout_)) {
        resp.release();
        throw std::runtime_error("storage_download_stream timed out");
    }

    if (!isOk(resp->status())) {
        throw std::runtime_error("storage_download_stream failed: " + resp->data());
    }

    return resp->progressBytes();
}

std::string StorageClient::call(const char* name, const AsyncCall& fn) {
    auto resp = std::make_unique<StorageResponse>();
    const int dispatchRet = fn(callback, resp.get());
    if (!isOk(dispatchRet)) {
        throw std::runtime_error(std::string(name) + " dispatch failed");
    }

    if (!resp->wait(timeout_)) {
        resp.release();
        throw std::runtime_error(std::string(name) + " timed out");
    }

    if (!isOk(resp->status())) {
        throw std::runtime_error(std::string(name) + " failed: " + resp->data());
    }

    return resp->data();
}

void StorageClient::callback(int callerRet, const char* msg, size_t len, void* userData) {
    if (auto* resp = static_cast<StorageResponse*>(userData)) {
        resp->setResult(callerRet, msg, len);
    }
}
