# Variables
ARG BUILDER=ubuntu:22.04
ARG IMAGE=${BUILDER}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=${MAKE_PARALLEL:-4}
ARG NIMFLAGS="${NIMFLAGS:-"-d:disableMarchNative"}"
ARG APP_HOME=/codex
ARG NAT_IP_AUTO=${NAT_IP_AUTO:-false}

# Build
FROM ${BUILDER} AS builder
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG NIMFLAGS

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential rustc cargo

WORKDIR ${BUILD_HOME}
COPY . .
RUN make clean
RUN make -j ${MAKE_PARALLEL} update
RUN make -j ${MAKE_PARALLEL}

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/codex /usr/local/bin
COPY --chmod=0755 docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 bash curl jq && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["codex"]
