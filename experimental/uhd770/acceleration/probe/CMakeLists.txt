cmake_minimum_required(VERSION 3.20)
project(uhd770_compute_probe LANGUAGES CXX)

# A headers-only dependency keeps this executable independent of the CI host's ICD.
find_path(VULKAN_INCLUDE_DIR vulkan/vulkan.h REQUIRED)
find_program(GLSLANG_VALIDATOR glslangValidator REQUIRED)
find_package(Threads REQUIRED)

add_custom_command(
    OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/verify.comp.spv"
    COMMAND "${GLSLANG_VALIDATOR}" -V --target-env vulkan1.1
            -o "${CMAKE_CURRENT_BINARY_DIR}/verify.comp.spv"
            "${CMAKE_CURRENT_SOURCE_DIR}/verify.comp"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/verify.comp"
    VERBATIM)
add_custom_target(probe_shader ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/verify.comp.spv")

add_executable(uhd770-compute-probe main.cpp)
target_compile_features(uhd770-compute-probe PRIVATE cxx_std_17)
target_include_directories(uhd770-compute-probe PRIVATE "${VULKAN_INCLUDE_DIR}")
target_link_libraries(uhd770-compute-probe PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
if(MSVC)
    target_compile_options(uhd770-compute-probe PRIVATE /W4 /WX /permissive-)
else()
    target_compile_options(uhd770-compute-probe PRIVATE -Wall -Wextra -Werror)
endif()
add_dependencies(uhd770-compute-probe probe_shader)
# Deliberately no add_test(): CI builds the executable and shader without opening a GPU.
