#pragma once

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

extern "C" {
#include "libstorage.h"
}

class StorageResponse {
public:
    StorageResponse() = default;
    StorageResponse(const StorageResponse&) = delete;
    StorageResponse& operator=(const StorageResponse&) = delete;

    void setResult(int callerRet, const char* msg, size_t len);
    bool wait(std::chrono::milliseconds timeout = std::chrono::seconds(60));

    int status() const;
    std::string data() const;
    size_t progressCount() const;
    size_t progressBytes() const;
    std::string lastProgress() const;

private:
    mutable std::mutex mtx_;
    std::condition_variable cv_;
    bool done_ = false;
    int status_ = -1;
    std::string result_;
    size_t progressCount_ = 0;
    size_t progressBytes_ = 0;
    std::string lastProgress_;
};

class StorageClient {
public:
    explicit StorageClient(
        std::string configJson,
        std::chrono::milliseconds timeout = std::chrono::seconds(120));
    StorageClient(const StorageClient&) = delete;
    StorageClient& operator=(const StorageClient&) = delete;
    ~StorageClient();

    void start();
    void stop();
    void close();

    std::string version() const;
    std::string revision() const;
    std::string repo();
    std::string peerId();
    std::string metrics();
    std::string debug();
    std::string spr();
    std::string list();
    std::string space();
    std::string manifest(const std::string& cid);
    std::string exists(const std::string& cid);
    std::string deleteContent(const std::string& cid);
    std::string fetch(const std::string& cid);
    std::string connect(const std::string& peerId, const std::vector<std::string>& peerAddresses);
    std::string uploadFile(const std::string& filepath, size_t chunkSize);
    std::string downloadFile(
        const std::string& cid,
        const std::string& outputPath,
        size_t chunkSize,
        bool local);
    size_t streamSink(const std::string& cid, size_t chunkSize, bool local);

private:
    using AsyncCall = std::function<int(StorageCallback, void*)>;

    std::string call(const char* name, const AsyncCall& fn);
    static void callback(int callerRet, const char* msg, size_t len, void* userData);

    void* ctx_ = nullptr;
    std::chrono::milliseconds timeout_;
    bool started_ = false;
    bool closed_ = false;
};
