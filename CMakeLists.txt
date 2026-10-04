cmake_minimum_required(VERSION 3.16)
project(skk-zenz LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/llama.cpp)
if(NOT EXISTS ${LLAMA_DIR}/CMakeLists.txt)
  message(FATAL_ERROR
    "llama.cpp submodule is missing. Run: git submodule update --init --depth 1")
endif()

# The server version follows the Emacs package version, so that a release tag
# names both.
file(STRINGS skk-zenz.el ZENZ_VERSION_LINE REGEX "^;; Version: " LIMIT_COUNT 1)
string(REGEX MATCH "Version: *([^ ;]+)" ZENZ_VERSION_MATCH "${ZENZ_VERSION_LINE}")
set(ZENZ_VERSION "${CMAKE_MATCH_1}")
if(NOT ZENZ_VERSION)
  message(FATAL_ERROR "No Version header in skk-zenz.el")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS skk-zenz.el)

# A portable build runs on CPUs other than the build machine's and needs only
# the C library at run time. It is used for release binaries.
option(ZENZ_PORTABLE "Build a zenz-server that runs on other machines" OFF)
if(ZENZ_PORTABLE)
  # Without GGML_NATIVE, ggml enables AVX2, FMA, F16C, and BMI2 on x86_64
  # (x86-64-v3) and the base instruction set elsewhere.
  set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
  set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
endif()

# Build only libllama/ggml, statically, CPU only.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
foreach(opt LLAMA_BUILD_COMMON LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS
            LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_BUILD_APP
            LLAMA_BUILD_UI LLAMA_OPENSSL)
  set(${opt} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory(${LLAMA_DIR} EXCLUDE_FROM_ALL)

add_library(zenz_prompt STATIC src/prompt.cpp)
target_include_directories(zenz_prompt PUBLIC src)

add_library(zenz_model STATIC src/model.cpp)
target_include_directories(zenz_model PUBLIC src)
target_link_libraries(zenz_model PUBLIC llama)

# nlohmann/json is vendored by llama.cpp.
add_library(zenz_protocol STATIC src/protocol.cpp)
target_include_directories(zenz_protocol PUBLIC src ${LLAMA_DIR}/vendor)
target_link_libraries(zenz_protocol PUBLIC zenz_prompt)
target_compile_definitions(zenz_protocol PRIVATE ZENZ_VERSION="${ZENZ_VERSION}")

add_executable(zenz-server src/main.cpp)
target_link_libraries(zenz-server PRIVATE zenz_prompt zenz_model zenz_protocol)
if(ZENZ_PORTABLE)
  target_link_options(zenz-server PRIVATE -static-libstdc++ -static-libgcc)
endif()

enable_testing()

add_executable(test_prompt tests/test_prompt.cpp)
target_link_libraries(test_prompt PRIVATE zenz_prompt)
add_test(NAME prompt COMMAND test_prompt)

add_executable(test_protocol tests/test_protocol.cpp)
target_link_libraries(test_protocol PRIVATE zenz_protocol)
add_test(NAME protocol COMMAND test_protocol)

add_executable(test_model tests/test_model.cpp)
target_link_libraries(test_model PRIVATE zenz_prompt zenz_model)
add_test(NAME model COMMAND test_model)
set_tests_properties(model PROPERTIES SKIP_RETURN_CODE 77)

# --prompt needs no model, so the command line can be checked without one.
add_test(NAME cli_max_context
         COMMAND zenz-server --max-context 3 --left 一二三四五 --prompt あ)
set_tests_properties(cli_max_context PROPERTIES
                     PASS_REGULAR_EXPRESSION "三四五" FAIL_REGULAR_EXPRESSION "二")

add_test(NAME cli_version COMMAND zenz-server --version)
set_tests_properties(cli_version PROPERTIES PASS_REGULAR_EXPRESSION
                     "\"version\":\"${ZENZ_VERSION}\"")
