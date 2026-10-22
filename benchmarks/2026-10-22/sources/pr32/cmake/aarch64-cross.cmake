set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

find_program(GCC_C NAMES aarch64-linux-gnu-gcc REQUIRED)
find_program(GCC_CXX NAMES aarch64-linux-gnu-g++ REQUIRED)
find_program(GCC_AR NAMES aarch64-linux-gnu-gcc-ar REQUIRED)
find_program(GCC_RANLIB NAMES aarch64-linux-gnu-gcc-ranlib REQUIRED)
set(CMAKE_C_COMPILER "${GCC_C}")
set(CMAKE_CXX_COMPILER "${GCC_CXX}")
set(CMAKE_AR "${GCC_AR}")
set(CMAKE_RANLIB "${GCC_RANLIB}")

# -march=native means nothing when cross-compiling; armv8.2-a covers Graviton 2+, Ampere and Apple M-series.
set(CMAKE_C_FLAGS_RELEASE_INIT "-O3 -march=armv8.2-a -flto=auto -DNDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-O3 -march=armv8.2-a -flto=auto -DNDEBUG")

set(CMAKE_EXE_LINKER_FLAGS_RELEASE_INIT "-s")

set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
