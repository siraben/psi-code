# psi firmware: ESP-IDF top-level project. Brings in the components
# tree alongside the firmware directory so `psi` and `forth-cmod`
# resolve as standard ESP-IDF components.
cmake_minimum_required(VERSION 3.16)

set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../components/psi"
    "${CMAKE_CURRENT_LIST_DIR}/../components/forth-cmod"
)

# psi/main is the app_main shim; psi/components/psi carries the
# C agent core and the WS server.
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(psi_firmware)
