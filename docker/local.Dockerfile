FROM thatbenbierens/codexsetup:latest AS builder
WORKDIR /src
COPY ./codex ./codex
COPY ./docker ./docker
RUN make NIM_PARAMS="-d:disableMarchNative"

FROM alpine:3.17.2
WORKDIR /root/
RUN apk add --no-cache openssl libstdc++ libgcc libgomp
COPY --from=builder /src/build/codex ./
COPY --from=builder /src/docker/startCodex.sh ./
CMD ["sh", "startCodex.sh"]
