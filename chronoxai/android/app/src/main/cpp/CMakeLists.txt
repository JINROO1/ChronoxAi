cmake_minimum_required(VERSION 3.22.1)
project(chronoxai_local_llm LANGUAGES C CXX)

# Build all embedded .so files with Android 15's 16 KB page-size alignment.
add_link_options("-Wl,-z,max-page-size=16384")

include(FetchContent)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)

FetchContent_Declare(
    llama_cpp
    GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
    GIT_TAG 3ba1ce0e28d991800e1585b7d3533f77213939d6
    GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(llama_cpp)

add_library(chronox_local_llm SHARED local_llm_jni.cpp)
target_compile_features(chronox_local_llm PRIVATE cxx_std_17)
target_include_directories(chronox_local_llm PRIVATE ${llama_cpp_SOURCE_DIR}/include)
target_link_libraries(chronox_local_llm PRIVATE llama log android)
