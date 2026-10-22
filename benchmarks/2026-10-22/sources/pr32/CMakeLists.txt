cmake_minimum_required(VERSION 3.25)
project(twelve_dollar_eastl LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

include(FetchContent)
FetchContent_Declare(eastl
        GIT_REPOSITORY https://github.com/electronicarts/EASTL.git
        GIT_TAG 3.27.01
        GIT_SHALLOW ON
)
FetchContent_Declare(yyjson
        GIT_REPOSITORY https://github.com/ibireme/yyjson.git
        GIT_TAG 0.13.0
        GIT_SHALLOW ON
        EXCLUDE_FROM_ALL
)
FetchContent_Declare(sqlite
        URL https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
        URL_HASH SHA256=1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d
        DOWNLOAD_EXTRACT_TIMESTAMP ON
)
set(YYJSON_BUILD_TESTS OFF CACHE BOOL "")
set(YYJSON_BUILD_MISC OFF CACHE BOOL "")
set(YYJSON_INSTALL OFF CACHE BOOL "")
FetchContent_MakeAvailable(eastl yyjson sqlite)

find_package(OpenSSL REQUIRED)
find_library(URING_LIBRARY uring REQUIRED)
find_path(URING_INCLUDE_DIR liburing.h REQUIRED)
find_package(Threads REQUIRED)
find_package(GTest REQUIRED)

set(SQLITE_PGO_DIR ${CMAKE_BINARY_DIR}/sqlite-pgo)
set(SQLITE_PGO_LIB ${SQLITE_PGO_DIR}/libsqlite3_pgo.a)
add_custom_command(
        OUTPUT ${SQLITE_PGO_LIB}
        COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/pgo/build_sqlite.sh
                ${sqlite_SOURCE_DIR} ${SQLITE_PGO_DIR} ${CMAKE_C_COMPILER} ${CMAKE_CXX_COMPILER} ${CMAKE_AR}
                ${CMAKE_CURRENT_SOURCE_DIR}/pgo/train.cpp
        DEPENDS pgo/build_sqlite.sh pgo/train.cpp ${sqlite_SOURCE_DIR}/sqlite3.c
        COMMENT "Building SQLite with profile-guided optimization"
        VERBATIM
)
add_custom_target(sqlite_pgo DEPENDS ${SQLITE_PGO_LIB})
add_library(sqlite3_pgo STATIC IMPORTED)
set_target_properties(sqlite3_pgo PROPERTIES
        IMPORTED_LOCATION ${SQLITE_PGO_LIB}
        INTERFACE_INCLUDE_DIRECTORIES ${sqlite_SOURCE_DIR}
        INTERFACE_LINK_LIBRARIES "Threads::Threads;m"
)

add_library(core STATIC)
target_sources(core
        PRIVATE
        src/app.cpp
        src/db.cpp
        src/eastl_hooks.cpp
        src/http.cpp
        src/json.cpp
        src/jwt.cpp
        src/response.cpp
        src/server.cpp
)
target_link_libraries(core PUBLIC EASTL OpenSSL::Crypto sqlite3_pgo ${URING_LIBRARY})
add_dependencies(core sqlite_pgo)
target_include_directories(core PUBLIC ${URING_INCLUDE_DIR})
target_compile_options(core PRIVATE -Wall -Wextra)
target_compile_definitions(core PUBLIC OPENSSL_SUPPRESS_DEPRECATED)
option(SRV_SIMD_SCALAR "Use the portable scalar scans instead of SSE2/NEON" OFF)
if(SRV_SIMD_SCALAR)
    target_compile_definitions(core PUBLIC SRV_SIMD_SCALAR)
endif()

add_executable(server src/main.cpp)
target_link_libraries(server PRIVATE core)

enable_testing()
add_executable(unit_tests)
target_sources(unit_tests
        PRIVATE
        tests/app_test.cpp
        tests/db_test.cpp
        tests/http_fuzz_test.cpp
        tests/http_test.cpp
        tests/json_fuzz_test.cpp
        tests/json_test.cpp
        tests/server_test.cpp
        tests/simd_test.cpp
        tests/jwt_test.cpp
        tests/sqlite_build_test.cpp
        tests/writer_test.cpp
)
target_include_directories(unit_tests PRIVATE src)
target_link_libraries(unit_tests PRIVATE core yyjson GTest::gtest_main)
add_test(NAME unit_tests COMMAND unit_tests)
