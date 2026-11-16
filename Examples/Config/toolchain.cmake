# Cross-compilation toolchain
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

add_compile_options(-Wall -Wextra $<$<CONFIG:Debug>:-fsanitize=address>)
