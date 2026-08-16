# syntax=docker/dockerfile:1.7
# =============================================================================
# MarketReplay-Core — development / verification container
#
# Provides the toolchain for the single-threaded replay path and its
# AddressSanitizer / UndefinedBehaviorSanitizer runs.
#
# Build the dev image:
#   docker build --target dev -t marketreplay:dev .
#
# Run it (bind-mount the repo; ASan needs a relaxed seccomp profile on some
# Docker versions):
#   docker run --rm -it \
#     -v "$PWD":/workspace \
#     --cap-add=SYS_PTRACE \
#     --security-opt seccomp=unconfined \
#     marketreplay:dev
#
# Inside:
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
#   ctest --test-dir build --output-on-failure
#
# GIT OVER SSH
#   No key material is baked into the image. To push from inside the container,
#   forward the host's SSH agent and mount known_hosts read-only:
#     Linux:
#       -v "$SSH_AUTH_SOCK":/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent \
#       -v "$HOME/.ssh/known_hosts":/home/dev/.ssh/known_hosts:ro
#     macOS (Docker Desktop):
#       -v /run/host-services/ssh-auth.sock:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent \
#       -v "$HOME/.ssh/known_hosts":/home/dev/.ssh/known_hosts:ro
#   Without known_hosts, the first push stalls on an interactive host-key
#   prompt; alternatively run `ssh-keyscan github.com >> ~/.ssh/known_hosts`
#   inside the container. Pushing from the host instead works just as well —
#   the bind-mounted tree is the same working tree.
#
# Clean-checkout verification (builds + runs the full matrix at image build time):
#   docker build --target ci -t marketreplay:ci .
#
# BENCHMARKING CAVEAT
#   Numbers taken inside a container share the host's cores, scheduler, frequency
#   governor and page cache. Treat container runs as smoke tests. For numbers
#   that get published, run on the host, or at minimum pin cores:
#     docker run --rm --cpuset-cpus=2,3 ... marketreplay:dev ./build/bin/bench_direct
#   and record that the run was containerised.
# =============================================================================

ARG UBUNTU_VERSION=24.04

# -----------------------------------------------------------------------------
# base — toolchain only, shared by dev and ci
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS base

ARG GCC_VERSION=14
ARG CLANG_VERSION=18
ARG INSTALL_PERF=0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=UTC

# Optional package mirror, e.g. --build-arg APT_MIRROR=mirrors.ustc.edu.cn
# Left empty by default so the image builds identically anywhere. Kept on http:
# the base image has no ca-certificates yet at this point.
ARG APT_MIRROR=
RUN if [ -n "${APT_MIRROR}" ]; then \
        sed -i \
          -e "s|http://archive.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
          -e "s|http://security.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
          -e "s|http://ports.ubuntu.com/ubuntu-ports|http://${APT_MIRROR}/ubuntu-ports|g" \
          /etc/apt/sources.list.d/ubuntu.sources ; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        g++-${GCC_VERSION} \
        clang-${CLANG_VERSION} \
        lld-${CLANG_VERSION} \
        llvm-${CLANG_VERSION} \
        cmake \
        ninja-build \
        git \
        ca-certificates \
        openssh-client \
        python3 \
        gdb \
        libc6-dbg \
        file \
        less \
        procps \
        time \
    && rm -rf /var/lib/apt/lists/*

# perf is optional and off by default: the containerised build almost never
# matches the host kernel, and it needs --cap-add=PERFMON (or --privileged) plus
# a permissive kernel.perf_event_paranoid on the host.
RUN if [ "${INSTALL_PERF}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            linux-tools-common linux-tools-generic \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Make the versioned compilers the unversioned defaults.
RUN update-alternatives --install /usr/bin/gcc  gcc  /usr/bin/gcc-${GCC_VERSION} 100 \
        --slave /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} \
        --slave /usr/bin/gcov gcov /usr/bin/gcov-${GCC_VERSION} \
 && update-alternatives --install /usr/bin/clang   clang   /usr/bin/clang-${CLANG_VERSION} 100 \
        --slave /usr/bin/clang++ clang++ /usr/bin/clang++-${CLANG_VERSION}

ENV CMAKE_GENERATOR=Ninja

# Sanitizer defaults. Halt/abort on the first error so CTest actually fails
# instead of printing a warning and returning 0.
ENV ASAN_OPTIONS="abort_on_error=1:halt_on_error=1:detect_leaks=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1"
ENV UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

# Symbolized sanitizer stacks.
ENV ASAN_SYMBOLIZER_PATH=/usr/lib/llvm-${CLANG_VERSION}/bin/llvm-symbolizer

# -----------------------------------------------------------------------------
# dev — interactive image, repo bind-mounted at /workspace
# -----------------------------------------------------------------------------
FROM base AS dev

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Ubuntu 24.04 ships a default 'ubuntu' user at uid 1000; remove it if it
# collides with the uid we want, so bind-mounted files keep sane ownership.
RUN if getent passwd ${USER_UID} >/dev/null; then \
        existing="$(getent passwd ${USER_UID} | cut -d: -f1)"; \
        userdel -r "$existing" 2>/dev/null || true; \
    fi \
 && groupadd -g ${USER_GID} ${USERNAME} 2>/dev/null || true \
 && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USERNAME}

WORKDIR /workspace
RUN chown ${USER_UID}:${USER_GID} /workspace
USER ${USERNAME}

# git complains about bind-mounted repos owned by another uid.
RUN git config --global --add safe.directory /workspace

CMD ["/bin/bash"]

# -----------------------------------------------------------------------------
# ci — clean-checkout verification, runs at image build time
#
# Release build with warnings-as-errors plus the test suite, then an ASan/UBSan
# build plus the test suite. Any failing step fails the image build.
# -----------------------------------------------------------------------------
FROM base AS ci

WORKDIR /src
COPY . /src

# 1. Release build — everything compiles warning-free, all tests pass.
RUN cmake -S . -B build-release \
        -DCMAKE_BUILD_TYPE=Release \
        -DMR_WARNINGS_AS_ERRORS=ON \
 && cmake --build build-release -j"$(nproc)" \
 && ctest --test-dir build-release --output-on-failure --timeout 900

# 2. ASan + UBSan build — correctness only, benchmarks excluded.
RUN cmake -S . -B build-asan \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DMR_SANITIZER=address+undefined \
        -DMR_BUILD_BENCH=OFF \
 && cmake --build build-asan -j"$(nproc)" \
 && ctest --test-dir build-asan --output-on-failure --timeout 1800

CMD ["/bin/bash"]

# -----------------------------------------------------------------------------
# bench — measurement image, for the x86-64 Linux host only
#
# MR_MEASUREMENT_BUILD=ON makes the configure step fail unless the host can
# actually produce trustworthy numbers, so this stage cannot be built on an
# arm64 machine or in a non-Release configuration.
#
#   docker build --target bench -t marketreplay:bench .
#   docker run --rm -it --cpuset-cpus=2,3 marketreplay:bench
#   > taskset -c 2 ./bin/bench_book
#
# The container shares the host scheduler and page cache. That is acceptable on
# a dedicated box, but record that the run was containerised — or build on the
# host directly and remove one layer from the story.
# -----------------------------------------------------------------------------
FROM base AS bench

WORKDIR /src
COPY . /src

RUN cmake -S . -B build-bench \
        -DCMAKE_BUILD_TYPE=Release \
        -DMR_MEASUREMENT_BUILD=ON \
        -DMR_NATIVE_ARCH=ON \
 && cmake --build build-bench -j"$(nproc)" \
 && ctest --test-dir build-bench --output-on-failure --timeout 900

WORKDIR /src/build-bench
CMD ["/bin/bash"]