#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace {
std::string homeDir() {
    const char* home = std::getenv("HOME");
    if (!home || std::strlen(home) == 0) {
        throw std::runtime_error("HOME is not set");
    }
    return home;
}

std::string defaultSocketPath() {
    const char* fromEnv = std::getenv("STORAGE_LIB_SOCKET");
    if (fromEnv && std::strlen(fromEnv) > 0) {
        return fromEnv;
    }
    return homeDir() + "/.logos/storage/libstorage/storage_lib.sock";
}

void printUsage() {
    std::cout <<
        "Usage:\n"
        "  storage_lib_ctl [--socket <path>] <command> [args]\n\n"
        "Commands are sent as one line to storage_lib. Examples:\n"
        "  storage_lib_ctl info\n"
        "  storage_lib_ctl upload README.md\n"
        "  storage_lib_ctl download <cid> ./out true\n"
        "  storage_lib_ctl stop\n"
        "  storage_lib_ctl start\n"
        "  storage_lib_ctl close\n"
        "  storage_lib_ctl shutdown\n"
        "  storage_lib_ctl destroy\n";
}

struct Options {
    std::string socketPath;
    std::vector<std::string> command;
};

Options parseArgs(int argc, char** argv) {
    Options options;
    options.socketPath = defaultSocketPath();

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            printUsage();
            std::exit(0);
        } else if (arg == "--socket" && i + 1 < argc) {
            options.socketPath = argv[++i];
        } else if (!arg.empty() && arg[0] == '-') {
            throw std::runtime_error("unknown or incomplete option: " + arg);
        } else {
            for (; i < argc; ++i) {
                options.command.emplace_back(argv[i]);
            }
            break;
        }
    }

    if (options.command.empty()) {
        throw std::runtime_error("missing command");
    }
    return options;
}

std::string commandLine(const std::vector<std::string>& command) {
    std::string line;
    for (size_t i = 0; i < command.size(); ++i) {
        if (i > 0) line += ' ';
        line += command[i];
    }
    line += '\n';
    return line;
}

int connectSocket(const std::string& socketPath) {
    if (socketPath.size() >= sizeof(sockaddr_un::sun_path)) {
        throw std::runtime_error("socket path is too long: " + socketPath);
    }

    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) throw std::runtime_error(std::string("socket failed: ") + std::strerror(errno));

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, socketPath.c_str(), sizeof(addr.sun_path) - 1);

    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        throw std::runtime_error(std::string("connect failed: ") + std::strerror(errno));
    }
    return fd;
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

std::string readAll(int fd) {
    std::string out;
    char buffer[4096];
    while (true) {
        ssize_t n = ::read(fd, buffer, sizeof(buffer));
        if (n == 0) break;
        if (n < 0) throw std::runtime_error(std::string("read failed: ") + std::strerror(errno));
        out.append(buffer, static_cast<size_t>(n));
    }
    return out;
}
}

int main(int argc, char** argv) {
    try {
        const Options options = parseArgs(argc, argv);
        int fd = connectSocket(options.socketPath);
        writeAll(fd, commandLine(options.command));
        ::shutdown(fd, SHUT_WR);
        const std::string response = readAll(fd);
        ::close(fd);

        std::cout << response;
        return response.find("\"ok\":false") == std::string::npos ? 0 : 1;
    } catch (const std::exception& err) {
        std::cerr << "error: " << err.what() << "\n";
        return 1;
    }
}
