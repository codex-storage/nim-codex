FROM nimlang/nim:1.6.10-alpine AS builder
WORKDIR /src
RUN apk update && apk add git cmake curl make git bash linux-headers
COPY . .
RUN make clean
RUN make update
