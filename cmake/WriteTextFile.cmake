if(NOT OUTPUT_FILE)
    message(FATAL_ERROR "OUTPUT_FILE is required")
endif()
file(WRITE "${OUTPUT_FILE}" "${OUTPUT_VALUE}\n")
