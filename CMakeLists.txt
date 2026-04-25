# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences

cmake_minimum_required(VERSION 3.22)
project(matlab-ctl LANGUAGES CXX VERSION 0.1.0)

#
# macOS-only, Intel + Apple Silicon. Windows and Linux are non-goals
# for v0.1; see docs/PLAN.md "Non-goals".
#
if(NOT APPLE)
    message(FATAL_ERROR
        "matlab-ctl currently targets macOS only. "
        "See docs/PLAN.md if you need other platforms.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

#
# Default to producing a fat binary so one .mexmaci64 / .mexmaca64
# loads on both Intel and Apple Silicon MATLAB.
#
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING
        "Universal binary architectures for the MEX")
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

#
# ---- MATLAB ----
#
# CMake's built-in FindMatlab works when MATLAB_ROOT or the MATLAB
# executable is on PATH. On macOS, R2025b and friends install to
# /Applications/MATLAB_R<ver>.app; CMake finds them automatically.
#
find_package(Matlab REQUIRED COMPONENTS MEX_COMPILER MX_LIBRARY)
message(STATUS "MATLAB: ${Matlab_ROOT_DIR}")

#
# ---- CTL ----
#
# Three ways to point at CTL, in priority order:
#
#   1. Developer build:  -DCTL_SOURCE_DIR=... -DCTL_BUILD_DIR=...
#                        Static-link to libIlmCtl*.a from your own
#                        CTL checkout. Use this when iterating on CTL.
#
#   2. Homebrew:         -DCTL_FROM_BREW=ON
#                        Use `brew install ctl` (formula version
#                        1.5.5 today). Shared-link to dylibs in the
#                        brew prefix.
#
#   3. FetchContent:     -DCTL_FETCH=ON
#                        Clone aces-aswf/CTL@ctl-1.5.5 into the build
#                        tree as a CMake subproject. Static-link.
#                        First configure pays a one-time CTL compile.
#
# build.sh handles discovery so end users typically don't pick a
# mode by hand. The MEX only uses the public Ctl::Interpreter /
# Ctl::FunctionCall / Ctl::FunctionArg API, so any of the three
# produces a working link.
#
if(CTL_SOURCE_DIR AND CTL_BUILD_DIR)
    # ---- Mode 1: developer build (static libs in a CTL build tree) ----
    find_library(CTL_IlmCtl_LIB
        NAMES IlmCtl
        PATHS "${CTL_BUILD_DIR}/lib/IlmCtl"
        NO_DEFAULT_PATH
        REQUIRED)
    find_library(CTL_IlmCtlSimd_LIB
        NAMES IlmCtlSimd
        PATHS "${CTL_BUILD_DIR}/lib/IlmCtlSimd"
        NO_DEFAULT_PATH
        REQUIRED)
    find_library(CTL_IlmCtlMath_LIB
        NAMES IlmCtlMath
        PATHS "${CTL_BUILD_DIR}/lib/IlmCtlMath"
        NO_DEFAULT_PATH
        REQUIRED)

    add_library(CTL::IlmCtl STATIC IMPORTED)
    set_target_properties(CTL::IlmCtl PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtl_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_SOURCE_DIR}/lib/IlmCtl")

    add_library(CTL::IlmCtlSimd STATIC IMPORTED)
    set_target_properties(CTL::IlmCtlSimd PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtlSimd_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_SOURCE_DIR}/lib/IlmCtlSimd")

    add_library(CTL::IlmCtlMath STATIC IMPORTED)
    set_target_properties(CTL::IlmCtlMath PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtlMath_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_SOURCE_DIR}/lib/IlmCtlMath")

    message(STATUS "CTL: developer build")
    message(STATUS "  source: ${CTL_SOURCE_DIR}")
    message(STATUS "  build : ${CTL_BUILD_DIR}")

elseif(CTL_FROM_BREW)
    # ---- Mode 2: Homebrew (shared libs at brew --prefix ctl) ----
    execute_process(
        COMMAND brew --prefix ctl
        OUTPUT_VARIABLE CTL_BREW_PREFIX
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _brew_rc)
    if(NOT _brew_rc EQUAL 0 OR NOT EXISTS "${CTL_BREW_PREFIX}")
        message(FATAL_ERROR
            "CTL_FROM_BREW=ON but `brew --prefix ctl` failed. "
            "Install with `brew install ctl` first.")
    endif()

    find_library(CTL_IlmCtl_LIB
        NAMES IlmCtl
        PATHS "${CTL_BREW_PREFIX}/lib"
        NO_DEFAULT_PATH
        REQUIRED)
    find_library(CTL_IlmCtlSimd_LIB
        NAMES IlmCtlSimd
        PATHS "${CTL_BREW_PREFIX}/lib"
        NO_DEFAULT_PATH
        REQUIRED)
    find_library(CTL_IlmCtlMath_LIB
        NAMES IlmCtlMath
        PATHS "${CTL_BREW_PREFIX}/lib"
        NO_DEFAULT_PATH
        REQUIRED)

    add_library(CTL::IlmCtl SHARED IMPORTED)
    set_target_properties(CTL::IlmCtl PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtl_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_BREW_PREFIX}/include/CTL")

    add_library(CTL::IlmCtlSimd SHARED IMPORTED)
    set_target_properties(CTL::IlmCtlSimd PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtlSimd_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_BREW_PREFIX}/include/CTL")

    add_library(CTL::IlmCtlMath SHARED IMPORTED)
    set_target_properties(CTL::IlmCtlMath PROPERTIES
        IMPORTED_LOCATION "${CTL_IlmCtlMath_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CTL_BREW_PREFIX}/include/CTL")

    message(STATUS "CTL: Homebrew at ${CTL_BREW_PREFIX}")

elseif(CTL_FETCH)
    # ---- Mode 3: FetchContent (clone + build CTL as a subproject) ----
    include(FetchContent)
    set(CTL_FETCH_TAG "ctl-1.5.5" CACHE STRING
        "aces-aswf/CTL git tag to fetch")
    set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
    set(CTL_BUILD_TESTS  OFF CACHE BOOL "" FORCE)
    set(CTL_BUILD_TOOLS  OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(CTL
        GIT_REPOSITORY https://github.com/aces-aswf/CTL.git
        GIT_TAG        "${CTL_FETCH_TAG}"
        GIT_SHALLOW    TRUE)
    FetchContent_MakeAvailable(CTL)

    # CTL's CMakeLists creates targets named IlmCtl / IlmCtlSimd /
    # IlmCtlMath without a namespace; alias them so the rest of this
    # CMakeLists is mode-agnostic.
    add_library(CTL::IlmCtl     ALIAS IlmCtl)
    add_library(CTL::IlmCtlSimd ALIAS IlmCtlSimd)
    add_library(CTL::IlmCtlMath ALIAS IlmCtlMath)

    message(STATUS "CTL: FetchContent ${CTL_FETCH_TAG}")

else()
    message(FATAL_ERROR
        "No CTL specified. Pick one of:\n"
        "  -DCTL_SOURCE_DIR=/path/to/CTL -DCTL_BUILD_DIR=/path/to/CTL/build\n"
        "  -DCTL_FROM_BREW=ON    (requires `brew install ctl`)\n"
        "  -DCTL_FETCH=ON        (clone aces-aswf/CTL@ctl-1.5.5)\n"
        "Most users run ./build.sh, which handles discovery.")
endif()

#
# ---- Imath / OpenEXR (CTL's transitive deps) ----
#
# Homebrew ships Imath 3.x headers; CTL's IlmBase path also works.
#
find_package(Imath CONFIG REQUIRED)
find_package(OpenEXR CONFIG REQUIRED)

#
# ---- MEX target ----
#
#
# Accelerate.framework is a transitive dep of libIlmCtlSimd when CTL
# was built with CTL_USE_ACCELERATE=ON (the default on Apple). It
# supplies vvsqrtf / vvexpf / vvlogf / vvpowf etc. that the CTL SIMD
# interpreter's transcendental dispatch references. If the CTL build
# used CTL_USE_ACCELERATE=OFF, linking still succeeds because
# Accelerate's symbols go unresolved but unused.
#
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)

#
# libut ships with MATLAB and exports utIsInterruptPending, the
# hook a MEX polls to notice Ctrl+C during long compute. Not part
# of the headers under extern/include, but the symbol is stable
# and universally available in MATLAB installs.
#
find_library(MATLAB_UT_LIB
    NAMES ut
    PATHS "${Matlab_ROOT_DIR}/bin/maca64"
          "${Matlab_ROOT_DIR}/bin/maci64"
    NO_DEFAULT_PATH
    REQUIRED)

matlab_add_mex(
    NAME apply_ctl_mex
    SRC mex/apply_ctl_mex.cpp
    LINK_TO
        CTL::IlmCtlSimd
        CTL::IlmCtlMath
        CTL::IlmCtl
        Imath::Imath
        OpenEXR::Iex
        ${ACCELERATE_FRAMEWORK}
        ${MATLAB_UT_LIB}
    R2018a
)

#
# Place the compiled .mex* alongside the .m wrapper in src/, so a
# single `addpath src` in MATLAB picks up both at once.
#
set_target_properties(apply_ctl_mex PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/src"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/src")
