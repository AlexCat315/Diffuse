function(json_escape OUT_VAR VALUE)
    set(_value "${VALUE}")
    string(REPLACE "\\" "\\\\" _value "${_value}")
    string(REPLACE "\"" "\\\"" _value "${_value}")
    string(REPLACE "\n" "\\n" _value "${_value}")
    string(REPLACE "\r" "\\r" _value "${_value}")
    string(REPLACE "\t" "\\t" _value "${_value}")
    set(${OUT_VAR} "${_value}" PARENT_SCOPE)
endfunction()

if(NOT MANIFEST_PATH)
    message(FATAL_ERROR "MANIFEST_PATH is required")
endif()
if(NOT LIB_PATH)
    message(FATAL_ERROR "LIB_PATH is required")
endif()
if(NOT EXISTS "${LIB_PATH}")
    message(FATAL_ERROR "Cannot write ${MANIFEST_PATH}: library does not exist: ${LIB_PATH}")
endif()

file(SHA256 "${LIB_PATH}" LIB_SHA256)
string(TIMESTAMP BUILT_AT_UTC "%Y-%m-%dT%H:%M:%SZ" UTC)

foreach(_name
    ARTIFACT_NAME
    ARTIFACT_VERSION
    CONFIGURATION
    BUILD_SYSTEM
    SOURCE_KIND
    SOURCE_URL
    SOURCE_REF
    SOURCE_REVISION
    LIB_REL_PATH
    LIB_SHA256
    C_COMPILER
    CXX_COMPILER
    RUSTC
    CARGO
    C_FLAGS_RELEASE
    CXX_FLAGS_RELEASE
    RUST_FLAGS
    NOTES
    BUILT_AT_UTC
)
    json_escape("${_name}_JSON" "${${_name}}")
endforeach()

file(WRITE "${MANIFEST_PATH}" "{
  \"schemaVersion\": \"1.0\",
  \"artifact\": {
    \"name\": \"${ARTIFACT_NAME_JSON}\",
    \"version\": \"${ARTIFACT_VERSION_JSON}\"
  },
  \"configuration\": \"${CONFIGURATION_JSON}\",
  \"buildSystem\": \"${BUILD_SYSTEM_JSON}\",
  \"source\": {
    \"kind\": \"${SOURCE_KIND_JSON}\",
    \"url\": \"${SOURCE_URL_JSON}\",
    \"ref\": \"${SOURCE_REF_JSON}\",
    \"revision\": \"${SOURCE_REVISION_JSON}\"
  },
  \"library\": {
    \"path\": \"${LIB_REL_PATH_JSON}\",
    \"sha256\": \"${LIB_SHA256_JSON}\"
  },
  \"toolchain\": {
    \"cCompiler\": \"${C_COMPILER_JSON}\",
    \"cxxCompiler\": \"${CXX_COMPILER_JSON}\",
    \"rustc\": \"${RUSTC_JSON}\",
    \"cargo\": \"${CARGO_JSON}\"
  },
  \"flags\": {
    \"cRelease\": \"${C_FLAGS_RELEASE_JSON}\",
    \"cxxRelease\": \"${CXX_FLAGS_RELEASE_JSON}\",
    \"rust\": \"${RUST_FLAGS_JSON}\"
  },
  \"notes\": \"${NOTES_JSON}\",
  \"builtAtUtc\": \"${BUILT_AT_UTC_JSON}\"
}
")
