# Variables
ARG BUILDER=ubuntu:lunar-20230415
ARG IMAGE=${BUILDER}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=${MAKE_PARALLEL:-4}
ARG NIMFLAGS="${NIMFLAGS:-"-d:disableMarchNative -d:chronosDurationThreshold=1000000 -d:chronosFutureTracking -d:codex_enable_api_debug_peers=true"}"
ARG APP_HOME=/codex
ARG NAT_IP_AUTO=${NAT_IP_AUTO:-false}

# Build
FROM ${BUILDER} AS builder
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG NIMFLAGS

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential nim
RUN echo 'export NIMBLE_DIR="${HOME}/.nimble"' >> "${HOME}/.bash_env"
RUN echo 'export PATH="${NIMBLE_DIR}/bin:${PATH}"' >> "${HOME}/.bash_env"

WORKDIR ${BUILD_HOME}
COPY . .
RUN make clean
RUN make -j ${MAKE_PARALLEL} update
COPY docker/asyncloop.nim ./vendor/nim-chronos/chronos
RUN make -j ${MAKE_PARALLEL}

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/codex /usr/local/bin
COPY --chmod=0755 docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 bash && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["codex"]
