# Variables
ARG BUILDER=ubuntu:lunar-20230415
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

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential nim
RUN curl --proto '=https' --tlsv1.3 https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR ${BUILD_HOME}
COPY . .
RUN ./env.sh make clean
RUN ./env.sh make -j ${MAKE_PARALLEL} update
RUN ./env.sh make -j ${MAKE_PARALLEL}

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/codex /usr/local/bin
COPY --chmod=0755 docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 bash curl && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["codex"]
