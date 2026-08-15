cmake_minimum_required(VERSION 3.14)
project(MarketReplayCore CXX)

# Enforce C++20 standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Configure strict compiler warnings & errors for GCC/Clang
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(
        -Wall
        -Wextra
        -Wpedantic
        # --- Critical Warning-to-Error Upgrades for Systems Programming ---
        -Werror=unused-result       # Enforce [[nodiscard]] (prevent resource leaks)
        -Werror=return-type         # Prevent Undefined Behavior from missing return statements
        -Werror=uninitialized       # Prevent reading uninitialized raw memory/variables
        -Werror=maybe-uninitialized # Catch conditional uninitialized variables
        -Werror=conversion          # Prevent silent truncation (e.g., uint64_t to 32-bit price_ticks)
        -Werror=sign-compare        # Prevent signed vs unsigned integer mismatch bugs
        -Werror=shadow              # Prevent variable shadowing in nested scopes/locks
    )
endif()

# --- Dependencies ---
# Thread support is mandatory for the Bounded SPSC pipeline & CPU affinity
find_package(Threads REQUIRED)

# --- Sanitizer Configurations ---
option(ENABLE_ASAN_UBSAN "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
option(ENABLE_TSAN "Enable ThreadSanitizer" OFF)

if(ENABLE_ASAN_UBSAN AND ENABLE_TSAN)
    message(FATAL_ERROR "ASan/UBSan cannot be enabled at the same time as TSan!")
endif()

if(ENABLE_ASAN_UBSAN)
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()

if(ENABLE_TSAN)
    add_compile_options(-fsanitize=thread -fno-omit-frame-pointer)
    add_link_options(-fsanitize=thread)
endif()

# --- Core Library ---
# Build the core MarketReplay library
add_library(marketreplay_core
    src/binary_format.cpp
    src/replay_source.cpp
    src/l2_book.cpp
)

# Export the header directory for dependent targets including tests
target_include_directories(marketreplay_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
# Link threads for concurrent SPSC pipeline support
target_link_libraries(marketreplay_core PUBLIC Threads::Threads)

# --- Executables: Main ---
add_executable(marketreplay_main src/main.cpp)
target_link_libraries(marketreplay_main PRIVATE marketreplay_core)

# --- Executables: Tools ---
add_executable(normalize_csv tools/normalize_csv.cpp)
target_link_libraries(normalize_csv PRIVATE marketreplay_core)

add_executable(generate_dataset tools/generate_dataset.cpp)
target_link_libraries(generate_dataset PRIVATE marketreplay_core)

# --- Executables: Benchmarks ---
add_executable(bench_book bench/bench_book.cpp)
target_link_libraries(bench_book PRIVATE marketreplay_core)

add_executable(bench_direct bench/bench_direct.cpp)
target_link_libraries(bench_direct PRIVATE marketreplay_core)

add_executable(bench_spsc bench/bench_spsc.cpp)
target_link_libraries(bench_spsc PRIVATE marketreplay_core)

# --- Testing ---
# Enable CTest and include the tests subdirectory
enable_testing()
add_subdirectory(tests)