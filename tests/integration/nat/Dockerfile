FROM ubuntu:24.04

ARG NIM_VERSION=2.2.10

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ make cmake git curl ca-certificates xz-utils \
    libc-dev ccache \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Build miniupnpd with a stub redirector. miniupnpd normally calls iptables/nftables
# to install the actual port forwarding rules when it receives a mapping request.
# In Docker, those calls fail because the container lacks the required kernel
# capabilities, causing every mapping request to return an error to the client.
# The stub replaces the firewall backend with no-ops that always return success,
# so mapping requests complete normally without touching the kernel.
COPY tests/integration/nat/miniupnpd_stub_rdr.c /tmp/stub_rdr.c
RUN git clone --depth=1 --branch miniupnpd_2_3_9 \
        https://github.com/miniupnp/miniupnp.git /tmp/miniupnp \
    && cd /tmp/miniupnp/miniupnpd \
    && ./configure \
    && cp /tmp/stub_rdr.c . \
    && make NETFILTEROBJS=stub_rdr.o miniupnpd \
    && install -m 755 miniupnpd /usr/local/sbin/miniupnpd \
    && rm -rf /tmp/miniupnp /tmp/stub_rdr.c

# Install Nim
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s "/opt/nim-${NIM_VERSION}/bin/nim" /usr/local/bin/nim

WORKDIR /app

# Copy project source (build context must be the project root)
COPY vendor/ vendor/
COPY storage/ storage/
COPY library/ library/
COPY tests/ tests/
COPY build.nims config.nims storage.nim ./

# Build libplum C library and Nim binaries.
# ccache caches C compilation across builds; nimcache caches Nim's generated C files.
RUN --mount=type=cache,target=/root/.ccache \
    --mount=type=cache,target=/app/nimcache \
    export PATH="/usr/lib/ccache:$PATH" && \
    rm -rf vendor/nim-libplum/vendor/libplum/build && \
    cmake -B vendor/nim-libplum/vendor/libplum/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        vendor/nim-libplum/vendor/libplum && \
    make -j$(nproc) -C vendor/nim-libplum/vendor/libplum/build && \
    cp vendor/nim-libplum/vendor/libplum/build/libplum.a \
        vendor/nim-libplum/vendor/libplum/libplum.a && \
    USE_SYSTEM_NIM=1 vendor/nimbus-build-system/scripts/env.sh \
    nim buildNatPortMappingBinaries -d:debug -d:disable_libbacktrace build.nims

COPY tests/integration/nat/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
