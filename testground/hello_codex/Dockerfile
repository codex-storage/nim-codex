FROM nimlang/nim as builder

RUN apt update -qq && \
    DEBIAN_FRONTEND="noninteractive" apt install -yq cmake curl make

FROM builder

COPY . .

RUN cd /extra/scratch/nim-codex && make USE_SYSTEM_NIM=1 V=1 update

RUN cd /extra/scratch/nim-codex && make USE_SYSTEM_NIM=1 V=1 hello_codex

ENTRYPOINT ["/extra/scratch/nim-codex/build/hello_codex"]
