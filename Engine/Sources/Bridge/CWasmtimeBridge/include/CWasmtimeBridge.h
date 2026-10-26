#ifndef COVE_C_WASMTIME_BRIDGE_H
#define COVE_C_WASMTIME_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cove_wasmtime_runtime cove_wasmtime_runtime_t;

typedef struct cove_wasmtime_buffer {
  uint8_t *data;
  size_t size;
} cove_wasmtime_buffer_t;

typedef struct cove_wasmtime_limits {
  uint64_t maximum_memory_bytes;
  uint64_t fuel_per_invocation;
  int64_t maximum_table_elements;
  int64_t maximum_instances;
  int64_t maximum_tables;
  int64_t maximum_memories;
  size_t maximum_output_bytes;
  size_t maximum_query_request_bytes;
} cove_wasmtime_limits_t;

typedef enum cove_wasmtime_status {
  COVE_WASMTIME_OK = 0,
  COVE_WASMTIME_INVALID_ARGUMENT = 1,
  COVE_WASMTIME_IO_ERROR = 2,
  COVE_WASMTIME_COMPILE_ERROR = 3,
  COVE_WASMTIME_CONTRACT_MISMATCH = 4,
  COVE_WASMTIME_LINK_ERROR = 5,
  COVE_WASMTIME_INVOCATION_ERROR = 6,
  COVE_WASMTIME_OUTPUT_TOO_LARGE = 7,
  COVE_WASMTIME_QUERY_ERROR = 8,
  COVE_WASMTIME_OUT_OF_MEMORY = 9,
} cove_wasmtime_status_t;

/// Synchronous host callback for the three fixed Cove query interfaces.
/// Implementations must fill either `response` on success or `error` on
/// failure with `cove_wasmtime_buffer_copy`. The bridge releases both.
typedef int32_t (*cove_wasmtime_query_callback_t)(
    void *environment, const uint8_t *interface_name,
    size_t interface_name_size, const uint8_t *request, size_t request_size,
    cove_wasmtime_buffer_t *response, cove_wasmtime_buffer_t *error);

typedef enum cove_wasmtime_execution {
  COVE_WASMTIME_AUTOMATIC = 0,
  COVE_WASMTIME_INTERPRETER = 1,
} cove_wasmtime_execution_t;

const char *cove_wasmtime_runtime_version(void);

cove_wasmtime_runtime_t *
cove_wasmtime_runtime_new(cove_wasmtime_execution_t execution,
                          cove_wasmtime_buffer_t *error);

int32_t cove_wasmtime_runtime_is_interpreter(cove_wasmtime_runtime_t *runtime);

void cove_wasmtime_runtime_delete(cove_wasmtime_runtime_t *runtime);

/// Interrupts the active invocation by advancing the engine epoch. The host
/// process serialises invocations, so one runtime has at most one active call.
void cove_wasmtime_runtime_interrupt(cove_wasmtime_runtime_t *runtime);

cove_wasmtime_status_t cove_wasmtime_validate_component(
    cove_wasmtime_runtime_t *runtime, const char *component_path,
    const char *capabilities_interface_name,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
    const cove_wasmtime_limits_t *limits, cove_wasmtime_buffer_t *error);

cove_wasmtime_status_t cove_wasmtime_invoke_capability(
    cove_wasmtime_runtime_t *runtime, const char *component_path,
    const char *capabilities_interface_name, const char *capability_name,
    const uint8_t *typed_input,
    size_t typed_input_size,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
    cove_wasmtime_query_callback_t query_callback, void *query_environment,
    const cove_wasmtime_limits_t *limits, cove_wasmtime_buffer_t *output,
    cove_wasmtime_buffer_t *error);

/// Converts component text format to a binary. This is used by deterministic
/// bridge tests and never accepts plugin input in the production path.
cove_wasmtime_status_t cove_wasmtime_component_wat2wasm(
    const uint8_t *wat, size_t wat_size, cove_wasmtime_buffer_t *output,
    cove_wasmtime_buffer_t *error);

int32_t cove_wasmtime_buffer_copy(cove_wasmtime_buffer_t *buffer,
                                   const uint8_t *bytes, size_t size);

void cove_wasmtime_buffer_delete(cove_wasmtime_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
