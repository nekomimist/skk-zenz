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

add_executable(zenz-server src/main.cpp)
target_link_libraries(zenz-server PRIVATE zenz_prompt zenz_model)

enable_testing()

add_executable(test_prompt tests/test_prompt.cpp)
target_link_libraries(test_prompt PRIVATE zenz_prompt)
add_test(NAME prompt COMMAND test_prompt)

add_executable(test_model tests/test_model.cpp)
target_link_libraries(test_model PRIVATE zenz_prompt zenz_model)
add_test(NAME model COMMAND test_model)
set_tests_properties(model PROPERTIES SKIP_RETURN_CODE 77)
