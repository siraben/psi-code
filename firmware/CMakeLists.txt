# psi firmware: ESP-IDF top-level project. Brings in the components
# tree alongside the firmware directory so `psi` and `lua-cmod`
# resolve as standard ESP-IDF components.
cmake_minimum_required(VERSION 3.16)

set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../components/psi"
    "${CMAKE_CURRENT_LIST_DIR}/../components/lua-cmod"
    "${CMAKE_CURRENT_LIST_DIR}/../components/zlib-cmod"
)

# psi is the entire C/Lua agent core; main is just the app_main shim.
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(psi_firmware)
