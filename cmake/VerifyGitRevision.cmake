if(NOT REPO_DIR)
    message(FATAL_ERROR "REPO_DIR is required")
endif()
if(NOT EXPECTED_REVISION)
    message(FATAL_ERROR "EXPECTED_REVISION is required")
endif()

execute_process(
    COMMAND git -C "${REPO_DIR}" rev-parse HEAD
    OUTPUT_VARIABLE ACTUAL_REVISION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE REVISION_RESULT
)
if(NOT REVISION_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to read git revision for ${REPO_DIR}")
endif()

if(NOT ACTUAL_REVISION STREQUAL EXPECTED_REVISION)
    if(EXPECTED_REF)
        set(_ref_message " for ${EXPECTED_REF}")
    endif()
    message(FATAL_ERROR
        "Unexpected git revision${_ref_message}: expected ${EXPECTED_REVISION}, got ${ACTUAL_REVISION}"
    )
endif()
