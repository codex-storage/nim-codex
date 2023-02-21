FROM nimlang/nim:1.6.10-alpine AS builder
WORKDIR /src
RUN apk update && apk add git cmake curl make git bash linux-headers
COPY . .
RUN make clean
RUN make update
RUN make exec

FROM alpine:3.17.2
WORKDIR /root/
RUN apk add --no-cache openssl libstdc++ libgcc libgomp
COPY --from=builder /src/build/codex ./
CMD ["sh", "-c", "/root/codex --api-bindaddr=0.0.0.0 --api-port=${CDX_API_PORT} --data-dir=/datadir"]
