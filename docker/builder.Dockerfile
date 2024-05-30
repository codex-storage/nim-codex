# Variables
ARG BUILDER=ubuntu:24.04

# Build
FROM ${BUILDER} AS builder

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="$PATH:/root/.cargo/bin"
RUN cargo --version
RUN rustc --version
