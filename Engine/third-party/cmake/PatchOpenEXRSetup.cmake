set(_setup_file "${OPENEXR_SOURCE_DIR}/cmake/OpenEXRSetup.cmake")

if(NOT EXISTS "${_setup_file}")
    message(FATAL_ERROR "OpenEXR setup file not found: ${_setup_file}")
endif()

file(READ "${_setup_file}" _setup)

set(_old [=[
  file(CREATE_LINK
    "${openjph_SOURCE_DIR}/src/core/common"
    "${openjph_SOURCE_DIR}/src/core/openjph"
    SYMBOLIC
  )
]=])

set(_new [=[
  if(WIN32)
    # Windows requires symlink privileges; copy the directory instead.
    file(COPY "${openjph_SOURCE_DIR}/src/core/common/"
         DESTINATION "${openjph_SOURCE_DIR}/src/core/openjph")
  else()
    file(CREATE_LINK
      "${openjph_SOURCE_DIR}/src/core/common"
      "${openjph_SOURCE_DIR}/src/core/openjph"
      SYMBOLIC
    )
  endif()
]=])

string(FIND "${_setup}" "${_new}" _already_patched)
if(_already_patched GREATER_EQUAL 0)
    return()
endif()

string(FIND "${_setup}" "${_old}" _patch_offset)
if(_patch_offset LESS 0)
    message(FATAL_ERROR "OpenEXRSetup.cmake does not contain the expected OpenJPH symlink block")
endif()

string(REPLACE "${_old}" "${_new}" _setup "${_setup}")
file(WRITE "${_setup_file}" "${_setup}")
