#include "storage_client.hpp"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <exception>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
constexpr size_t DefaultChunkSize = 64 * 1024;

struct Options {
    std::string dataDir = "./storage-lib-cli-data";
    std::string logLevel = "WARN";
    size_t chunkSize = DefaultChunkSize;
    std::chrono::milliseconds timeout = std::chrono::seconds(120);
    bool local = false;
    bool noStart = false;
    std::string command;
    std::vector<std::string> args;
};

std::string jsonEscape(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        switch (ch) {
        case '\\':
            out += "\\\\";
            break;
        case '"':
            out += "\\\"";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            out += ch;
            break;
        }
    }
    return out;
}

std::string configJson(const Options& options) {
    return "{\"log-level\":\"" + jsonEscape(options.logLevel) + "\"," +
           "\"data-dir\":\"" + jsonEscape(options.dataDir) + "\"," +
           "\"metrics\":false}";
}

void printUsage() {
    std::cout <<
        "Usage:\n"
        "  storage_lib_cli [options] <command> [args]\n\n"
        "Options:\n"
        "  --data-dir <path>      Node data directory (default: ./storage-lib-cli-data)\n"
        "  --log-level <level>    TRACE, DEBUG, INFO, NOTICE, WARN, ERROR, FATAL\n"
        "  --chunk-size <bytes>   Upload/download chunk size (default: 65536)\n"
        "  --timeout-ms <ms>      Async operation timeout (default: 120000)\n"
        "  --local                Download from local store only\n"
        "  --no-start             Create context but do not start node before command\n\n"
        "Commands:\n"
        "  info                   Print version, revision, repo, and peer id\n"
        "  version                Print storage version\n"
        "  revision               Print storage revision\n"
        "  repo                   Print configured repo/data-dir\n"
        "  peer-id                Print node peer id\n"
        "  spr                    Print node signed peer record\n"
        "  debug                  Print node debug JSON\n"
        "  connect <peer-id> [addr...]\n"
        "                         Connect to peer using optional multiaddresses\n"
        "  metrics                Print metrics JSON\n"
        "  list                   Print local manifest list JSON\n"
        "  space                  Print storage space JSON\n"
        "  manifest <cid>         Print manifest JSON\n"
        "  exists <cid>           Check whether cid exists locally\n"
        "  delete <cid>           Delete locally stored content\n"
        "  fetch <cid>            Fetch content into the local store\n"
        "  upload <file>          Upload a file and print its cid\n"
        "  download <cid> <file>  Download cid into file\n"
        "  stream-sink <cid>      Stream cid and discard data; prints bytes\n"
        "  roundtrip <in> <out>   Upload, download, compare, and print cid\n"
        "  repeat-roundtrip <in> <out-prefix> <count>\n"
        "                         Repeat roundtrip in one node session\n"
        "  upload-many <file> <count>\n"
        "                         Upload same file repeatedly in one node session\n"
        "  download-many <cid> <out-prefix> <count>\n"
        "                         Download same cid repeatedly in one node session\n";
}

size_t parseSize(const std::string& value) {
    size_t pos = 0;
    const auto parsed = std::stoull(value, &pos);
    if (pos != value.size()) {
        throw std::runtime_error("invalid size: " + value);
    }
    return static_cast<size_t>(parsed);
}

int parseCount(const std::string& value) {
    const size_t parsed = parseSize(value);
    if (parsed == 0) {
        throw std::runtime_error("count must be greater than zero");
    }
    return static_cast<int>(parsed);
}

Options parseArgs(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            options.command = "help";
            return options;
        }
        if (arg == "--data-dir" && i + 1 < argc) {
            options.dataDir = argv[++i];
        } else if (arg == "--log-level" && i + 1 < argc) {
            options.logLevel = argv[++i];
        } else if (arg == "--chunk-size" && i + 1 < argc) {
            options.chunkSize = parseSize(argv[++i]);
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            options.timeout = std::chrono::milliseconds(parseSize(argv[++i]));
        } else if (arg == "--local") {
            options.local = true;
        } else if (arg == "--no-start") {
            options.noStart = true;
        } else if (!arg.empty() && arg[0] == '-') {
            throw std::runtime_error("unknown option: " + arg);
        } else {
            options.command = arg;
            for (++i; i < argc; ++i) {
                options.args.emplace_back(argv[i]);
            }
            return options;
        }
    }

    options.command = "help";
    return options;
}

void requireArgCount(const Options& options, size_t count) {
    if (options.args.size() != count) {
        throw std::runtime_error("command '" + options.command + "' expects " +
                                 std::to_string(count) + " argument(s)");
    }
}

bool filesEqual(const std::string& leftPath, const std::string& rightPath) {
    std::ifstream left(leftPath, std::ios::binary);
    std::ifstream right(rightPath, std::ios::binary);
    if (!left || !right) {
        return false;
    }

    constexpr size_t BufferSize = 64 * 1024;
    std::vector<char> leftBuffer(BufferSize);
    std::vector<char> rightBuffer(BufferSize);
    while (left && right) {
        left.read(leftBuffer.data(), leftBuffer.size());
        right.read(rightBuffer.data(), rightBuffer.size());
        if (left.gcount() != right.gcount()) {
            return false;
        }
        if (!std::equal(
                leftBuffer.begin(),
                leftBuffer.begin() + left.gcount(),
                rightBuffer.begin())) {
            return false;
        }
    }

    return left.eof() && right.eof();
}

std::string indexedPath(const std::string& prefix, int index) {
    return prefix + "." + std::to_string(index);
}

std::string roundtrip(
    StorageClient& client,
    const Options& options,
    const std::string& inputPath,
    const std::string& outputPath) {
    const std::string cid = client.uploadFile(inputPath, options.chunkSize);
    client.downloadFile(cid, outputPath, options.chunkSize, options.local);
    if (!filesEqual(inputPath, outputPath)) {
        throw std::runtime_error("roundtrip byte comparison failed for cid: " + cid);
    }
    return cid;
}
}

int main(int argc, char** argv) {
    try {
        const Options options = parseArgs(argc, argv);
        if (options.command == "help") {
            printUsage();
            return 0;
        }

        StorageClient client(configJson(options), options.timeout);
        if (!options.noStart) {
            client.start();
        }

        if (options.command == "info") {
            requireArgCount(options, 0);
            std::cout << "version: " << client.version() << "\n";
            std::cout << "revision: " << client.revision() << "\n";
            std::cout << "repo: " << client.repo() << "\n";
            std::cout << "peer_id: " << client.peerId() << "\n";
        } else if (options.command == "version") {
            requireArgCount(options, 0);
            std::cout << client.version() << "\n";
        } else if (options.command == "revision") {
            requireArgCount(options, 0);
            std::cout << client.revision() << "\n";
        } else if (options.command == "repo") {
            requireArgCount(options, 0);
            std::cout << client.repo() << "\n";
        } else if (options.command == "peer-id") {
            requireArgCount(options, 0);
            std::cout << client.peerId() << "\n";
        } else if (options.command == "spr") {
            requireArgCount(options, 0);
            std::cout << client.spr() << "\n";
        } else if (options.command == "debug") {
            requireArgCount(options, 0);
            std::cout << client.debug() << "\n";
        } else if (options.command == "connect") {
            if (options.args.empty()) {
                throw std::runtime_error("command 'connect' expects at least 1 argument");
            }
            std::vector<std::string> addresses(options.args.begin() + 1, options.args.end());
            std::cout << client.connect(options.args[0], addresses) << "\n";
        } else if (options.command == "metrics") {
            requireArgCount(options, 0);
            std::cout << client.metrics() << "\n";
        } else if (options.command == "list") {
            requireArgCount(options, 0);
            std::cout << client.list() << "\n";
        } else if (options.command == "space") {
            requireArgCount(options, 0);
            std::cout << client.space() << "\n";
        } else if (options.command == "manifest") {
            requireArgCount(options, 1);
            std::cout << client.manifest(options.args[0]) << "\n";
        } else if (options.command == "exists") {
            requireArgCount(options, 1);
            std::cout << client.exists(options.args[0]) << "\n";
        } else if (options.command == "delete") {
            requireArgCount(options, 1);
            std::cout << client.deleteContent(options.args[0]) << "\n";
        } else if (options.command == "fetch") {
            requireArgCount(options, 1);
            std::cout << client.fetch(options.args[0]) << "\n";
        } else if (options.command == "upload") {
            requireArgCount(options, 1);
            std::cout << client.uploadFile(options.args[0], options.chunkSize) << "\n";
        } else if (options.command == "download") {
            requireArgCount(options, 2);
            std::cout << client.downloadFile(
                             options.args[0], options.args[1], options.chunkSize, options.local)
                      << "\n";
        } else if (options.command == "stream-sink") {
            requireArgCount(options, 1);
            std::cout << client.streamSink(options.args[0], options.chunkSize, options.local) << "\n";
        } else if (options.command == "roundtrip") {
            requireArgCount(options, 2);
            std::cout << roundtrip(client, options, options.args[0], options.args[1]) << "\n";
        } else if (options.command == "repeat-roundtrip") {
            requireArgCount(options, 3);
            const int count = parseCount(options.args[2]);
            std::string lastCid;
            for (int i = 1; i <= count; ++i) {
                lastCid = roundtrip(client, options, options.args[0], indexedPath(options.args[1], i));
                std::cout << i << " " << lastCid << "\n";
            }
            std::cout << "completed repeat-roundtrip count=" << count << " last_cid=" << lastCid
                      << "\n";
        } else if (options.command == "upload-many") {
            requireArgCount(options, 2);
            const int count = parseCount(options.args[1]);
            std::string lastCid;
            for (int i = 1; i <= count; ++i) {
                lastCid = client.uploadFile(options.args[0], options.chunkSize);
                std::cout << i << " " << lastCid << "\n";
            }
            std::cout << "completed upload-many count=" << count << " last_cid=" << lastCid << "\n";
        } else if (options.command == "download-many") {
            requireArgCount(options, 3);
            const int count = parseCount(options.args[2]);
            for (int i = 1; i <= count; ++i) {
                const std::string outputPath = indexedPath(options.args[1], i);
                client.downloadFile(options.args[0], outputPath, options.chunkSize, options.local);
                std::cout << i << " " << outputPath << "\n";
            }
            std::cout << "completed download-many count=" << count << "\n";
        } else {
            throw std::runtime_error("unknown command: " + options.command);
        }

        return 0;
    } catch (const std::exception& err) {
        std::cerr << "error: " << err.what() << "\n";
        return 1;
    }
}
