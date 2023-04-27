FROM ubuntu:lunar-20230415 AS builder
RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential nim
RUN echo 'export NIMBLE_DIR="${HOME}/.nimble"' >> "${HOME}/.bash_env"
RUN echo 'export PATH="${NIMBLE_DIR}/bin:${PATH}"' >> "${HOME}/.bash_env"

WORKDIR /src
COPY . .
RUN make clean
RUN make -j4 update
RUN make -j4 NIM_PARAMS="-d:disableMarchNative"

FROM ubuntu:lunar-20230415
WORKDIR /root
RUN apt-get update && apt-get install -y libgomp1 bash
COPY --from=builder /src/build/codex ./
COPY --from=builder /src/docker/startCodex.sh ./
RUN chmod +x ./startCodex.sh
CMD ["/bin/bash", "-l", "-c", "./startCodex.sh"]
