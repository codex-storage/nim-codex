#include "storage_client.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstring>
#include <exception>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr size_t DefaultChunkSize = 64 * 1024;

struct Options {
    std::string socketPath;
    std::string dataDir;
    std::string logLevel = "WARN";
    std::string network = "logos.test";
    uint16_t listenPort = 8071;
    uint16_t discPort = 8091;
    size_t chunkSize = DefaultChunkSize;
    std::chrono::milliseconds timeout = std::chrono::seconds(120);
};

std::atomic<bool> g_stop{false};
int g_serverFd = -1;

std::string homeDir() {
    const char* home = std::getenv("HOME");
    if (!home || std::strlen(home) == 0) {
        throw std::runtime_error("HOME is not set");
    }
    return home;
}

std::string defaultSocketPath() {
    return homeDir() + "/.logos/storage/libstorage/storage_lib.sock";
}

std::string defaultDataDir() {
    return homeDir() + "/.logos/storage/libstorage/node";
}

std::string jsonEscape(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        switch (ch) {
        case '\\': out += "\\\\"; break;
        case '"': out += "\\\""; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default: out += ch; break;
        }
    }
    return out;
}

std::string okResponse(const std::string& result) {
    return "{\"ok\":true,\"result\":\"" + jsonEscape(result) + "\"}\n";
}

std::string errorResponse(const std::string& error) {
    return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\"}\n";
}

std::string configJson(const Options& options) {
    return "{\"log-level\":\"" + jsonEscape(options.logLevel) + "\"," +
           "\"data-dir\":\"" + jsonEscape(options.dataDir) + "\"," +
           "\"network\":\"" + jsonEscape(options.network) + "\"," +
           "\"listen-port\":" + std::to_string(options.listenPort) + "," +
           "\"disc-port\":" + std::to_string(options.discPort) + "," +
           "\"metrics\":false}";
}

size_t parseSize(const std::string& value) {
    size_t pos = 0;
    const auto parsed = std::stoull(value, &pos);
    if (pos != value.size()) {
        throw std::runtime_error("invalid size: " + value);
    }
    return static_cast<size_t>(parsed);
}

uint16_t parsePort(const std::string& value) {
    const size_t parsed = parseSize(value);
    if (parsed == 0 || parsed > 65535) {
        throw std::runtime_error("invalid port: " + value);
    }
    return static_cast<uint16_t>(parsed);
}

bool parseBool(const std::string& value) {
    if (value == "true" || value == "1" || value == "yes") {
        return true;
    }
    if (value == "false" || value == "0" || value == "no") {
        return false;
    }
    throw std::runtime_error("invalid boolean: " + value);
}

std::vector<std::string> splitLine(const std::string& line) {
    std::istringstream input(line);
    std::vector<std::string> parts;
    std::string part;
    while (input >> part) {
        parts.push_back(part);
    }
    return parts;
}

void printUsage() {
    std::cout <<
        "Usage:\n"
        "  storage_lib [options]\n\n"
        "Options:\n"
        "  --socket <path>       Unix socket path\n"
        "  --data-dir <path>     Node data directory\n"
        "  --log-level <level>   TRACE, DEBUG, INFO, NOTICE, WARN, ERROR, FATAL\n"
        "  --listen-port <port>  Local libp2p TCP listen port (default: 8071)\n"
        "  --disc-port <port>    Local discovery UDP port (default: 8091)\n"
        "  --network <name>      Network preset (default: logos.test)\n"
        "  --chunk-size <bytes>  Upload/download chunk size (default: 65536)\n"
        "  --timeout-ms <ms>     Async operation timeout, 0 waits forever (default: 120000)\n"
        "  -h, --help            Show this help\n";
}

Options parseArgs(int argc, char** argv) {
    Options options;
    options.socketPath = defaultSocketPath();
    options.dataDir = defaultDataDir();

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            printUsage();
            std::exit(0);
        } else if (arg == "--socket" && i + 1 < argc) {
            options.socketPath = argv[++i];
        } else if (arg == "--data-dir" && i + 1 < argc) {
            options.dataDir = argv[++i];
        } else if (arg == "--log-level" && i + 1 < argc) {
            options.logLevel = argv[++i];
        } else if (arg == "--listen-port" && i + 1 < argc) {
            options.listenPort = parsePort(argv[++i]);
        } else if (arg == "--disc-port" && i + 1 < argc) {
            options.discPort = parsePort(argv[++i]);
        } else if (arg == "--network" && i + 1 < argc) {
            options.network = argv[++i];
        } else if (arg == "--chunk-size" && i + 1 < argc) {
            options.chunkSize = parseSize(argv[++i]);
        } else if (arg == "--timeout-ms" && i + 1 < argc) {
            options.timeout = std::chrono::milliseconds(parseSize(argv[++i]));
        } else {
            throw std::runtime_error("unknown or incomplete option: " + arg);
        }
    }

    return options;
}

std::string infoResult(StorageClient& client) {
    return "{\"version\":\"" + jsonEscape(client.version()) + "\"," +
           "\"revision\":\"" + jsonEscape(client.revision()) + "\"," +
           "\"repo\":\"" + jsonEscape(client.repo()) + "\"," +
           "\"peer_id\":\"" + jsonEscape(client.peerId()) + "\"}";
}

std::string dispatch(StorageClient& client, const Options& options, const std::string& line) {
    const auto parts = splitLine(line);
    if (parts.empty()) {
        throw std::runtime_error("empty command");
    }

    const auto& cmd = parts[0];
    if (cmd == "info") return infoResult(client);
    if (cmd == "version") return client.version();
    if (cmd == "revision") return client.revision();
    if (cmd == "repo") return client.repo();
    if (cmd == "peer-id" || cmd == "peerid") return client.peerId();
    if (cmd == "spr") return client.spr();
    if (cmd == "debug") return client.debug();
    if (cmd == "metrics") return client.metrics();
    if (cmd == "list") return client.list();
    if (cmd == "space") return client.space();

    if (cmd == "upload") {
        if (parts.size() != 2) throw std::runtime_error("usage: upload <file>");
        return client.uploadFile(parts[1], options.chunkSize);
    }
    if (cmd == "download") {
        if (parts.size() < 3 || parts.size() > 4) {
            throw std::runtime_error("usage: download <cid> <file> [local]");
        }
        const bool local = parts.size() == 4 ? parseBool(parts[3]) : false;
        return client.downloadFile(parts[1], parts[2], options.chunkSize, local);
    }
    if (cmd == "stream-sink") {
        if (parts.size() < 2 || parts.size() > 3) {
            throw std::runtime_error("usage: stream-sink <cid> [local]");
        }
        const bool local = parts.size() == 3 ? parseBool(parts[2]) : false;
        return std::to_string(client.streamSink(parts[1], options.chunkSize, local));
    }
    if (cmd == "exists") {
        if (parts.size() != 2) throw std::runtime_error("usage: exists <cid>");
        return client.exists(parts[1]);
    }
    if (cmd == "delete") {
        if (parts.size() != 2) throw std::runtime_error("usage: delete <cid>");
        return client.deleteContent(parts[1]);
    }
    if (cmd == "fetch") {
        if (parts.size() != 2) throw std::runtime_error("usage: fetch <cid>");
        return client.fetch(parts[1]);
    }
    if (cmd == "manifest") {
        if (parts.size() != 2) throw std::runtime_error("usage: manifest <cid>");
        return client.manifest(parts[1]);
    }
    if (cmd == "connect") {
        if (parts.size() < 2) throw std::runtime_error("usage: connect <peer-id> [addr...]");
        std::vector<std::string> addresses(parts.begin() + 2, parts.end());
        return client.connect(parts[1], addresses);
    }
    if (cmd == "shutdown") {
        g_stop = true;
        return "shutting down";
    }

    throw std::runtime_error("unknown command: " + cmd);
}

std::string readLine(int fd) {
    std::string line;
    char ch = '\0';
    while (true) {
        ssize_t n = ::read(fd, &ch, 1);
        if (n == 0) break;
        if (n < 0) throw std::runtime_error(std::string("read failed: ") + std::strerror(errno));
        if (ch == '\n') break;
        line += ch;
    }
    return line;
}

void writeAll(int fd, const std::string& data) {
    const char* ptr = data.data();
    size_t left = data.size();
    while (left > 0) {
        ssize_t n = ::write(fd, ptr, left);
        if (n < 0) throw std::runtime_error(std::string("write failed: ") + std::strerror(errno));
        ptr += n;
        left -= static_cast<size_t>(n);
    }
}

int createServerSocket(const std::string& socketPath) {
    if (socketPath.size() >= sizeof(sockaddr_un::sun_path)) {
        throw std::runtime_error("socket path is too long: " + socketPath);
    }

    std::filesystem::create_directories(std::filesystem::path(socketPath).parent_path());
    ::unlink(socketPath.c_str());

    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) throw std::runtime_error(std::string("socket failed: ") + std::strerror(errno));

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);

    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("bind failed: ") + std::strerror(errno));
    }
    if (::listen(fd, 16) < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("listen failed: ") + std::strerror(errno));
    }

    return fd;
}

void handleSignal(int) {
    g_stop = true;
    if (g_serverFd >= 0) {
        ::close(g_serverFd);
        g_serverFd = -1;
    }
}
}

int main(int argc, char** argv) {
    try {
        const Options options = parseArgs(argc, argv);

        std::signal(SIGINT, handleSignal);
        std::signal(SIGTERM, handleSignal);

        StorageClient client(configJson(options), options.timeout);
        client.start();

        g_serverFd = createServerSocket(options.socketPath);
        std::cout << "storage_lib listening on " << options.socketPath << "\n";
        std::cout.flush();

        while (!g_stop) {
            int clientFd = ::accept(g_serverFd, nullptr, nullptr);
            if (clientFd < 0) {
                if (g_stop) break;
                if (errno == EINTR) continue;
                throw std::runtime_error(std::string("accept failed: ") + std::strerror(errno));
            }

            try {
                const std::string line = readLine(clientFd);
                writeAll(clientFd, okResponse(dispatch(client, options, line)));
            } catch (const std::exception& err) {
                writeAll(clientFd, errorResponse(err.what()));
            }
            ::close(clientFd);
        }

        if (g_serverFd >= 0) {
            ::close(g_serverFd);
            g_serverFd = -1;
        }
        ::unlink(options.socketPath.c_str());
        return 0;
    } catch (const std::exception& err) {
        std::cerr << "error: " << err.what() << "\n";
        return 1;
    }
}
