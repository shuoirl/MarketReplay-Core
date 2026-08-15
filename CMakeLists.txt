# =============================================================================
# MarketReplay-Core — build configuration
#
# Builds the single-threaded replay path: MdEvent / BinaryHeader / CSV
# normalizer / BinaryReplaySource / L2Book / direct replay, together with the
# test suite and the two single-threaded benchmarks, under ASan and UBSan.
#
# The bounded SPSC ring and everything downstream of it (its tests, its
# benchmark, ThreadSanitizer runs) are not part of this build. No concurrent
# code is compiled here, so none can be run or claimed.
#
# Quick start:
#   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
#   ctest --test-dir build --output-on-failure
#
# Sanitizer build (correctness only, NEVER for measurement):
#   cmake -S . -B build-asan -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
#         -DMR_SANITIZER=address+undefined
# =============================================================================

cmake_minimum_required(VERSION 3.20)

project(MarketReplayCore
    VERSION     0.7.0
    DESCRIPTION "Deterministic market-data replay and performance experiment engine"
    LANGUAGES   CXX)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are disabled. Use: cmake -S . -B build")
endif()

# -----------------------------------------------------------------------------
# Global language settings
# -----------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)          # -std=c++20, not -std=gnu++20
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)  # for clang-tidy / editors
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
    message(STATUS "CMAKE_BUILD_TYPE not set -> defaulting to Release")
endif()
set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    Debug Release RelWithDebInfo MinSizeRel)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
option(MR_BUILD_TESTS        "Build unit / integration tests"          ON)
option(MR_BUILD_BENCH        "Build benchmark executables"             ON)
option(MR_BUILD_TOOLS        "Build normalize_csv / generate_dataset"  ON)
option(MR_WARNINGS_AS_ERRORS "Treat compiler warnings as errors"       OFF)
option(MR_NATIVE_ARCH        "Compile with -march=native (NOT portable; record it with any results)" OFF)
option(MR_ENABLE_LTO         "Enable interprocedural optimization"     OFF)
option(MR_KEEP_FRAME_POINTER "Keep frame pointers (needed for usable perf/ASan stacks)" ON)
option(MR_BENCH_SMOKE_TESTS  "Register tiny benchmark runs as ctest smoke tests" OFF)

set(MR_SANITIZER "none" CACHE STRING
    "Sanitizer: none | address | undefined | address+undefined | thread")
set_property(CACHE MR_SANITIZER PROPERTY STRINGS
    none address undefined address+undefined thread)

# -----------------------------------------------------------------------------
# Platform sanity checks
# -----------------------------------------------------------------------------
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(WARNING
        "Target platform is ${CMAKE_SYSTEM_NAME}. This project targets Linux x86-64; "
        "CPU affinity and TSC timing are unsupported elsewhere.")
endif()

set(MR_HAS_RDTSC 0)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
    set(MR_HAS_RDTSC 1)
else()
    message(WARNING
        "Processor '${CMAKE_SYSTEM_PROCESSOR}' is not x86-64: rdtsc/rdtscp latency "
        "sampling will be disabled (MR_HAS_RDTSC=0). Fall back to steady_clock "
        "batch timing and say so in the benchmark report.")
endif()

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 11)
    message(FATAL_ERROR "GCC >= 11 required for the C++20 subset used here.")
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 14)
    message(FATAL_ERROR "Clang >= 14 required for the C++20 subset used here.")
endif()

# -----------------------------------------------------------------------------
# Interface target: compile/link options shared by every target
# -----------------------------------------------------------------------------
add_library(mr_project_options INTERFACE)
add_library(mr::project_options ALIAS mr_project_options)

target_compile_features(mr_project_options INTERFACE cxx_std_20)
target_compile_definitions(mr_project_options INTERFACE
    MR_HAS_RDTSC=${MR_HAS_RDTSC})

if(MR_KEEP_FRAME_POINTER)
    target_compile_options(mr_project_options INTERFACE -fno-omit-frame-pointer)
endif()

if(MR_NATIVE_ARCH)
    include(CheckCXXCompilerFlag)
    check_cxx_compiler_flag("-march=native" MR_HAS_MARCH_NATIVE)
    if(MR_HAS_MARCH_NATIVE)
        target_compile_options(mr_project_options INTERFACE -march=native)
        set(MR_MARCH_SETTING "-march=native")
    else()
        message(WARNING "-march=native rejected by compiler; using default ISA")
        set(MR_MARCH_SETTING "default (native rejected)")
    endif()
else()
    set(MR_MARCH_SETTING "default (x86-64 baseline)")
endif()

if(MR_ENABLE_LTO)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT MR_IPO_OK OUTPUT MR_IPO_MSG)
    if(MR_IPO_OK)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
    else()
        message(WARNING "LTO requested but unsupported: ${MR_IPO_MSG}")
        set(MR_ENABLE_LTO OFF)
    endif()
endif()

# --- Sanitizers ---------------------------------------------------------------
# Sanitizers are attached to project_options so *every* target inherits them
# consistently (mixing instrumented and uninstrumented TUs is a good way to get
# false reports). MR_SANITIZED_BUILD is exposed to the code so benchmark output
# can loudly mark itself as unusable for measurement.
set(MR_SANITIZED_BUILD 0)
set(MR_SANITIZER_FLAGS "")

if(MR_SANITIZER STREQUAL "address")
    set(MR_SANITIZER_FLAGS -fsanitize=address)
elseif(MR_SANITIZER STREQUAL "undefined")
    set(MR_SANITIZER_FLAGS -fsanitize=undefined -fno-sanitize-recover=all)
elseif(MR_SANITIZER STREQUAL "address+undefined")
    set(MR_SANITIZER_FLAGS -fsanitize=address,undefined -fno-sanitize-recover=all)
elseif(MR_SANITIZER STREQUAL "thread")
    # Selectable so the option surface stays stable, but there is no concurrent
    # code in this build for it to find.
    set(MR_SANITIZER_FLAGS -fsanitize=thread)
elseif(NOT MR_SANITIZER STREQUAL "none")
    message(FATAL_ERROR "Unknown MR_SANITIZER='${MR_SANITIZER}'")
endif()

if(MR_SANITIZER_FLAGS)
    set(MR_SANITIZED_BUILD 1)
    target_compile_options(mr_project_options INTERFACE ${MR_SANITIZER_FLAGS} -g)
    target_link_options(mr_project_options INTERFACE ${MR_SANITIZER_FLAGS})
    if(MR_BUILD_BENCH)
        message(WARNING
            "Benchmarks are being built with MR_SANITIZER=${MR_SANITIZER}. "
            "Sanitized timings are meaningless — do not publish them. "
            "Binaries will print a SANITIZED BUILD banner.")
    endif()
endif()
target_compile_definitions(mr_project_options INTERFACE
    MR_SANITIZED_BUILD=${MR_SANITIZED_BUILD})

# --- Warnings -----------------------------------------------------------------
add_library(mr_warnings INTERFACE)
add_library(mr::warnings ALIAS mr_warnings)

target_compile_options(mr_warnings INTERFACE
    -Wall
    -Wextra
    -Wpedantic
    -Wshadow
    -Wconversion            # integer-width bugs are the whole point of this project
    -Wsign-conversion
    -Wcast-align
    -Wcast-qual
    -Wold-style-cast
    -Wnon-virtual-dtor
    -Wdouble-promotion      # catch accidental float paths near prices
    -Wformat=2
    -Wundef
    $<$<CXX_COMPILER_ID:GNU>:-Wlogical-op>
    $<$<CXX_COMPILER_ID:GNU>:-Wduplicated-cond>
    $<$<CXX_COMPILER_ID:GNU>:-Wduplicated-branches>
    $<$<CXX_COMPILER_ID:GNU>:-Wuseless-cast>
)
if(MR_WARNINGS_AS_ERRORS)
    target_compile_options(mr_warnings INTERFACE -Werror)
endif()

# -----------------------------------------------------------------------------
# Generated build metadata
#
# Every published measurement needs the toolchain and flags that produced it.
# Print this header from the benchmark binaries so their output is
# self-describing and cannot drift from the build that emitted it.
# -----------------------------------------------------------------------------
string(TOUPPER "${CMAKE_BUILD_TYPE}" MR_BUILD_TYPE_UPPER)
set(MR_ACTIVE_FLAGS "${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${MR_BUILD_TYPE_UPPER}}")
string(STRIP "${MR_ACTIVE_FLAGS}" MR_ACTIVE_FLAGS)

set(MR_GIT_REV "unknown")
find_package(Git QUIET)
if(GIT_FOUND AND EXISTS "${CMAKE_SOURCE_DIR}/.git")
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" describe --always --dirty --tags
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        OUTPUT_VARIABLE MR_GIT_REV
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
endif()

file(CONFIGURE
    OUTPUT "${CMAKE_BINARY_DIR}/generated/mr/build_info.hpp"
    @ONLY
    CONTENT [==[
// Generated by CMake. Do not edit.
// Print this from every benchmark run so results are self-describing.
#pragma once

namespace mr::build_info {

inline constexpr const char* project_version = "@PROJECT_VERSION@";
inline constexpr const char* git_revision    = "@MR_GIT_REV@";
inline constexpr const char* compiler_id     = "@CMAKE_CXX_COMPILER_ID@";
inline constexpr const char* compiler_ver    = "@CMAKE_CXX_COMPILER_VERSION@";
inline constexpr const char* build_type      = "@CMAKE_BUILD_TYPE@";
inline constexpr const char* cxx_flags       = "@MR_ACTIVE_FLAGS@";
inline constexpr const char* march_setting   = "@MR_MARCH_SETTING@";
inline constexpr const char* sanitizer       = "@MR_SANITIZER@";
inline constexpr bool        sanitized       = (@MR_SANITIZED_BUILD@ != 0);
inline constexpr bool        lto             = (@MR_ENABLE_LTO@ ? true : false);
inline constexpr bool        has_rdtsc       = (@MR_HAS_RDTSC@ != 0);

} // namespace mr::build_info
]==])

add_library(mr_build_info INTERFACE)
target_include_directories(mr_build_info INTERFACE "${CMAKE_BINARY_DIR}/generated")

# -----------------------------------------------------------------------------
# Core library
#
# Sources are listed explicitly (no GLOB): a missing file should break the build
# loudly, not silently drop a translation unit. Comment out any .cpp that does
# not exist yet.
# -----------------------------------------------------------------------------
add_library(mr_core STATIC
    src/binary_format.cpp
    src/replay_source.cpp
    src/l2_book.cpp
)
add_library(mr::core ALIAS mr_core)

target_include_directories(mr_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)

target_link_libraries(mr_core
    PUBLIC  mr::project_options mr_build_info
    PRIVATE mr::warnings)

# Nothing in the current sources spawns a thread, but linking pthread on Linux
# costs nothing and keeps the link line stable.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)
target_link_libraries(mr_core PUBLIC Threads::Threads)

# -----------------------------------------------------------------------------
# Main driver
# -----------------------------------------------------------------------------
add_executable(marketreplay src/main.cpp)
target_link_libraries(marketreplay PRIVATE mr::core mr::warnings)

# -----------------------------------------------------------------------------
# Tools (normalization + deterministic dataset generation)
# -----------------------------------------------------------------------------
if(MR_BUILD_TOOLS)
    foreach(tool normalize_csv generate_dataset)
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tools/${tool}.cpp")
            add_executable(${tool} tools/${tool}.cpp)
            target_link_libraries(${tool} PRIVATE mr::core mr::warnings)
        else()
            message(STATUS "tools/${tool}.cpp not present yet — skipping target")
        endif()
    endforeach()
endif()

# -----------------------------------------------------------------------------
# Tests
#
# Uses a header-only test helper at tests/mr_test.hpp (no external framework).
# Each test file is an independent executable registered with CTest, so one
# crash or ASan abort cannot take the whole suite down with it. Test files are
# registered only if they exist, so this file configures cleanly against a
# partially written test suite.
# -----------------------------------------------------------------------------
if(MR_BUILD_TESTS)
    enable_testing()

    add_library(mr_test_support INTERFACE)
    target_include_directories(mr_test_support INTERFACE
        "${CMAKE_CURRENT_SOURCE_DIR}/tests")
    target_compile_definitions(mr_test_support INTERFACE
        MR_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/data")

    function(mr_add_test test_name)
        cmake_parse_arguments(ARG "" "TIMEOUT" "LABELS" ${ARGN})
        set(src "${CMAKE_CURRENT_SOURCE_DIR}/tests/${test_name}.cpp")
        if(NOT EXISTS "${src}")
            message(STATUS "tests/${test_name}.cpp not present yet — skipping target")
            return()
        endif()

        add_executable(${test_name} "${src}")
        target_link_libraries(${test_name}
            PRIVATE mr::core mr::warnings mr_test_support)

        add_test(NAME ${test_name}
                 COMMAND ${test_name}
                 WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")

        if(NOT ARG_TIMEOUT)
            set(ARG_TIMEOUT 300)
        endif()
        set_tests_properties(${test_name} PROPERTIES
            TIMEOUT ${ARG_TIMEOUT}
            LABELS "${ARG_LABELS}")
    endfunction()

    # ctest -L unit   /   ctest -L integration   /   ctest -L slow
    mr_add_test(test_validation LABELS "unit")
    mr_add_test(test_binary     LABELS "unit")
    mr_add_test(test_l2_book    LABELS "unit")
    mr_add_test(test_replay     LABELS "integration")
    mr_add_test(test_reference  LABELS "integration;slow" TIMEOUT 900)
endif()

# -----------------------------------------------------------------------------
# Benchmarks
#
# Two workloads: the book update cost in isolation (events already in memory),
# and the full single-threaded replay path from the binary event file.
# -----------------------------------------------------------------------------
if(MR_BUILD_BENCH)
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        message(WARNING
            "Benchmarks are being built in Debug. Any numbers produced are noise. "
            "Use -DCMAKE_BUILD_TYPE=Release for measurement runs.")
    endif()

    foreach(bench bench_book bench_direct)
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/bench/${bench}.cpp")
            add_executable(${bench} bench/${bench}.cpp)
            target_include_directories(${bench} PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/bench")   # timer.hpp
            target_link_libraries(${bench} PRIVATE mr::core mr::warnings)
        else()
            message(STATUS "bench/${bench}.cpp not present yet — skipping target")
        endif()
    endforeach()

    # Optional: tiny benchmark runs registered as smoke tests, purely to prove the
    # binaries still run end-to-end. These are NOT measurements.
    # Assumes a `--events N` CLI flag; adjust to match your argument parser.
    if(MR_BENCH_SMOKE_TESTS AND MR_BUILD_TESTS AND NOT MR_SANITIZED_BUILD)
        foreach(bench bench_book bench_direct)
            if(TARGET ${bench})
                add_test(NAME ${bench}_smoke
                         COMMAND ${bench} --events 100000 --trials 1
                         WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
                set_tests_properties(${bench}_smoke PROPERTIES
                    TIMEOUT 120 LABELS "smoke")
            endif()
        endforeach()
    endif()
endif()

# -----------------------------------------------------------------------------
# Configuration summary — record this alongside any published measurement
# -----------------------------------------------------------------------------
message(STATUS "")
message(STATUS "==== MarketReplay-Core ${PROJECT_VERSION} ====")
message(STATUS "  git revision      : ${MR_GIT_REV}")
message(STATUS "  build type        : ${CMAKE_BUILD_TYPE}")
message(STATUS "  compiler          : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "  cxx flags         : ${MR_ACTIVE_FLAGS}")
message(STATUS "  -march            : ${MR_MARCH_SETTING}")
message(STATUS "  LTO               : ${MR_ENABLE_LTO}")
message(STATUS "  frame pointers    : ${MR_KEEP_FRAME_POINTER}")
message(STATUS "  sanitizer         : ${MR_SANITIZER}")
message(STATUS "  rdtsc available   : ${MR_HAS_RDTSC}")
message(STATUS "  tests / bench     : ${MR_BUILD_TESTS} / ${MR_BUILD_BENCH}")
message(STATUS "  warnings as errors: ${MR_WARNINGS_AS_ERRORS}")
message(STATUS "  concurrency       : none built (single-threaded replay only)")
message(STATUS "=============================================================")
message(STATUS "")