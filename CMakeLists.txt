cmake_minimum_required(VERSION 3.10)
project(tree_lattice LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")


include(CheckLanguage)
check_language(CUDA REQUIRED)
if(CMAKE_CUDA_COMPILER)
    enable_language(CUDA)
    message(STATUS "CUDA support")
else()
    message(STATUS "No CUDA support")
endif()

add_executable(tree_lattice main.cu random.cpp generator.cpp)
target_compile_features(tree_lattice PUBLIC cxx_std_14)