set(GUAVA_MANIFEST_WRITER "${CMAKE_CURRENT_LIST_DIR}/WriteArtifactBuildManifest.cmake")

function(guava_git_revision OUT_VAR SOURCE_DIR)
    execute_process(
        COMMAND git -C "${SOURCE_DIR}" rev-parse HEAD
        OUTPUT_VARIABLE _revision
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _result
    )
    if(_result EQUAL 0 AND NOT _revision STREQUAL "")
        set(${OUT_VAR} "${_revision}" PARENT_SCOPE)
    else()
        set(${OUT_VAR} "unknown" PARENT_SCOPE)
    endif()
endfunction()

function(guava_add_artifact_build_manifest)
    set(_one_value_args
        ARTIFACT_NAME
        VERSION
        BUNDLE_DIR
        LIB_REL_PATH
        CONFIGURATION
        BUILD_SYSTEM
        SOURCE_KIND
        SOURCE_URL
        SOURCE_REF
        SOURCE_REVISION
        C_COMPILER
        CXX_COMPILER
        RUSTC
        CARGO
        C_FLAGS_RELEASE
        CXX_FLAGS_RELEASE
        RUST_FLAGS
        NOTES
    )
    set(_multi_value_args DEPENDS)
    cmake_parse_arguments(ARG "" "${_one_value_args}" "${_multi_value_args}" ${ARGN})

    if(NOT ARG_ARTIFACT_NAME)
        message(FATAL_ERROR "guava_add_artifact_build_manifest requires ARTIFACT_NAME")
    endif()
    if(NOT ARG_BUNDLE_DIR)
        message(FATAL_ERROR "guava_add_artifact_build_manifest requires BUNDLE_DIR")
    endif()
    if(NOT ARG_LIB_REL_PATH)
        message(FATAL_ERROR "guava_add_artifact_build_manifest requires LIB_REL_PATH")
    endif()

    if(NOT ARG_CONFIGURATION)
        if(CMAKE_CONFIGURATION_TYPES)
            set(ARG_CONFIGURATION "$<CONFIG>")
        elseif(CMAKE_BUILD_TYPE)
            set(ARG_CONFIGURATION "${CMAKE_BUILD_TYPE}")
        else()
            set(ARG_CONFIGURATION "unknown")
        endif()
    endif()
    if(NOT ARG_BUILD_SYSTEM)
        set(ARG_BUILD_SYSTEM "CMake")
    endif()
    if(NOT ARG_C_COMPILER)
        set(ARG_C_COMPILER "${CMAKE_C_COMPILER}")
    endif()
    if(NOT ARG_CXX_COMPILER)
        set(ARG_CXX_COMPILER "${CMAKE_CXX_COMPILER}")
    endif()
    if(NOT ARG_C_FLAGS_RELEASE)
        set(ARG_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
    endif()
    if(NOT ARG_CXX_FLAGS_RELEASE)
        set(ARG_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE}")
    endif()

    set(_manifest_path "${ARG_BUNDLE_DIR}/build-manifest.json")
    set(_lib_path "${ARG_BUNDLE_DIR}/${ARG_LIB_REL_PATH}")
    string(MAKE_C_IDENTIFIER "${ARG_ARTIFACT_NAME}" _manifest_target_suffix)

    add_custom_target("manifest_${_manifest_target_suffix}" ALL
        COMMAND "${CMAKE_COMMAND}"
            "-DMANIFEST_PATH=${_manifest_path}"
            "-DARTIFACT_NAME=${ARG_ARTIFACT_NAME}"
            "-DARTIFACT_VERSION=${ARG_VERSION}"
            "-DCONFIGURATION=${ARG_CONFIGURATION}"
            "-DBUILD_SYSTEM=${ARG_BUILD_SYSTEM}"
            "-DSOURCE_KIND=${ARG_SOURCE_KIND}"
            "-DSOURCE_URL=${ARG_SOURCE_URL}"
            "-DSOURCE_REF=${ARG_SOURCE_REF}"
            "-DSOURCE_REVISION=${ARG_SOURCE_REVISION}"
            "-DLIB_PATH=${_lib_path}"
            "-DLIB_REL_PATH=${ARG_LIB_REL_PATH}"
            "-DC_COMPILER=${ARG_C_COMPILER}"
            "-DCXX_COMPILER=${ARG_CXX_COMPILER}"
            "-DRUSTC=${ARG_RUSTC}"
            "-DCARGO=${ARG_CARGO}"
            "-DC_FLAGS_RELEASE=${ARG_C_FLAGS_RELEASE}"
            "-DCXX_FLAGS_RELEASE=${ARG_CXX_FLAGS_RELEASE}"
            "-DRUST_FLAGS=${ARG_RUST_FLAGS}"
            "-DNOTES=${ARG_NOTES}"
            -P "${GUAVA_MANIFEST_WRITER}"
        DEPENDS ${ARG_DEPENDS}
        VERBATIM
        COMMENT "Writing build manifest for ${ARG_ARTIFACT_NAME}"
    )
endfunction()
