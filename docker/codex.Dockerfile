# Variables
ARG BUILDER=ubuntu:lunar-20230415
ARG IMAGE=${BUILDER}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=${MAKE_PARALLEL:-4}
ARG MAKE_PARAMS=${MAKE_PARAMS:-NIM_PARAMS="-d:disableMarchNative"}
ARG APP_HOME=/codex

# Build
FROM ${BUILDER} AS builder
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG MAKE_PARAMS

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential nim
RUN echo 'export NIMBLE_DIR="${HOME}/.nimble"' >> "${HOME}/.bash_env"
RUN echo 'export PATH="${NIMBLE_DIR}/bin:${PATH}"' >> "${HOME}/.bash_env"

WORKDIR ${BUILD_HOME}
COPY . .
RUN make clean
RUN make -j ${MAKE_PARALLEL} update
RUN make -j ${MAKE_PARALLEL} ${MAKE_PARAMS}

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/codex /usr/local/bin
COPY --chmod=0755 docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 bash && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["codex"]
