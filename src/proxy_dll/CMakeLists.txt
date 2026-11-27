cmake_minimum_required(VERSION 3.20)
project(pz2coop_proxy LANGUAGES CXX)

if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "PZ2-Coop version.dll must be built with MSVC for x64.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
# Static CRT: the proxy must not depend on whichever VC++ redist the game folder has.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

option(PZ2COOP_DEV_DIAG "Install verbose file/debug diagnostic IAT hooks and memory marker scanner" OFF)
add_compile_options(/W4 /WX /permissive- /utf-8)
# Release PDB (stays in build/, never shipped) so crash dumps map to source lines (tools/crashdump_info.py).
# /DEBUG would turn off /OPT:REF,ICF, so they are set explicitly to keep the shipped code unchanged.
add_compile_options($<$<CONFIG:Release>:/Zi>)
add_link_options($<$<CONFIG:Release>:/DEBUG> $<$<CONFIG:Release>:/OPT:REF> $<$<CONFIG:Release>:/OPT:ICF>)
add_compile_definitions(WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
if(PZ2COOP_DEV_DIAG)
    add_compile_definitions(PZ2COOP_DEV_DIAG=1)
endif()

# Networking + IPC core, shared by the DLL and the self-test.
add_library(pz2coop_core STATIC steam_p2p.cpp file_bridge.cpp mem_bridge.cpp diag.cpp ipc_bridge.cpp ui_overlay.cpp vehicle_patch.cpp)
target_link_libraries(pz2coop_core PUBLIC ws2_32 bcrypt crypt32)

# The proxy itself: drop version.dll next to PlanetZoo2.exe.
add_library(version SHARED dllmain.cpp version.def)
target_link_libraries(version PRIVATE pz2coop_core)
set_target_properties(version PROPERTIES OUTPUT_NAME "version" PREFIX "")

add_executable(pz2coop_selftest selftest.cpp)
target_link_libraries(pz2coop_selftest PRIVATE pz2coop_core)

enable_testing()
add_test(NAME selftest COMMAND pz2coop_selftest)
