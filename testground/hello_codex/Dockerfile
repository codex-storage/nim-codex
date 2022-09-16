FROM nimlang/nim as builder

RUN apt update -qq && \
    DEBIAN_FRONTEND="noninteractive" apt install -yq cmake curl make

FROM builder

COPY . .

RUN cd /extra/scratch/nim-codex && \
    make USE_SYSTEM_NIM=1 update

RUN cd /extra/scratch/nim-codex && \
    make USE_SYSTEM_NIM=1 TESTGROUND_PLAN=hello_codex testground_exec

ENTRYPOINT ["/extra/scratch/nim-codex/build/codex_testground"]
