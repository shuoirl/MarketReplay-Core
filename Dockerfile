FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    gdb \
    ninja-build \
    build-essential \
    g++ \
    libgtest-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

