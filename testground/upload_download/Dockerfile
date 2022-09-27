FROM nimbase

COPY . .

RUN cd /extra/scratch/nim-codex && \
    make USE_SYSTEM_NIM=1 update

RUN cd /extra/scratch/nim-codex && \
    make USE_SYSTEM_NIM=1 TESTGROUND_PLAN=upload_download testground_exec

ENTRYPOINT ["/extra/scratch/nim-codex/build/codex_testground"]
