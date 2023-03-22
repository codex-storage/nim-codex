FROM nimlang/nim:1.6.10-alpine AS builder
WORKDIR /src
RUN apk update && apk add git cmake curl make git bash linux-headers
COPY . .
RUN make clean
RUN make update
RUN make NIM_PARAMS="-d:disableMarchNative"

FROM alpine:3.17.2
WORKDIR /root/
RUN apk add --no-cache openssl libstdc++ libgcc libgomp
COPY --from=builder /src/build/codex ./
COPY --from=builder /src/docker/startCodex.sh ./
CMD ["sh", "startCodex.sh"]
