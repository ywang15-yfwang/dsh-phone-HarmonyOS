cmake_minimum_required(VERSION 3.5.0)
project(tailscale_ohos)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})
# libtailscale_go.h 是 Go c-shared 构建时生成的（见 harmonyos-app-toolchain\build-kernel-bridge.ps1）
include_directories(${NATIVERENDER_ROOT_PATH}/../../../../native/go_bridge/dist/arm64-v8a)

# Go 内核产物：libtailscale_go.so（ELF64 / AArch64 / DYN），由 entry/libs/<arch>/ 打进 HAP
add_library(tailscale_go SHARED IMPORTED)
set_target_properties(tailscale_go PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libtailscale_go.so)

add_library(tailscale_ohos SHARED napi_init.cpp)

target_link_libraries(tailscale_ohos PUBLIC tailscale_go libace_napi.z.so libhilog_ndk.z.so)

# 不把构建机绝对路径写进 RUNPATH（HAP 内不得出现本机路径；设备上依赖与本体同目录）
set_target_properties(tailscale_ohos PROPERTIES SKIP_BUILD_RPATH TRUE)


