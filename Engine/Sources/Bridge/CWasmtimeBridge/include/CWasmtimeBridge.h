#ifndef GUAVA_C_WASMTIME_BRIDGE_H
#define GUAVA_C_WASMTIME_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct guava_wasmtime_runtime guava_wasmtime_runtime_t;

typedef struct guava_wasmtime_buffer {
  uint8_t *data;
  size_t size;
} guava_wasmtime_buffer_t;

typedef struct guava_wasmtime_limits {
  uint64_t maximum_memory_bytes;
  uint64_t fuel_per_invocation;
  int64_t maximum_table_elements;
  int64_t maximum_instances;
  int64_t maximum_tables;
  int64_t maximum_memories;
  size_t maximum_output_bytes;
  size_t maximum_query_request_bytes;
} guava_wasmtime_limits_t;

typedef enum guava_wasmtime_status {
  GUAVA_WASMTIME_OK = 0,
  GUAVA_WASMTIME_INVALID_ARGUMENT = 1,
  GUAVA_WASMTIME_IO_ERROR = 2,
  GUAVA_WASMTIME_COMPILE_ERROR = 3,
  GUAVA_WASMTIME_CONTRACT_MISMATCH = 4,
  GUAVA_WASMTIME_LINK_ERROR = 5,
  GUAVA_WASMTIME_INVOCATION_ERROR = 6,
  GUAVA_WASMTIME_OUTPUT_TOO_LARGE = 7,
  GUAVA_WASMTIME_QUERY_ERROR = 8,
  GUAVA_WASMTIME_OUT_OF_MEMORY = 9,
} guava_wasmtime_status_t;

/// Synchronous host callback for the three fixed Guava query interfaces.
/// Implementations must fill either `response` on success or `error` on
/// failure with `guava_wasmtime_buffer_copy`. The bridge releases both.
typedef int32_t (*guava_wasmtime_query_callback_t)(
    void *environment, const uint8_t *interface_name,
    size_t interface_name_size, const uint8_t *request, size_t request_size,
    guava_wasmtime_buffer_t *response, guava_wasmtime_buffer_t *error);

const char *guava_wasmtime_runtime_version(void);

guava_wasmtime_runtime_t *
guava_wasmtime_runtime_new(guava_wasmtime_buffer_t *error);

void guava_wasmtime_runtime_delete(guava_wasmtime_runtime_t *runtime);

/// Interrupts the active invocation by advancing the engine epoch. The host
/// process serialises invocations, so one runtime has at most one active call.
void guava_wasmtime_runtime_interrupt(guava_wasmtime_runtime_t *runtime);

guava_wasmtime_status_t guava_wasmtime_validate_component(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *const *expected_imports, size_t expected_import_count,
    const guava_wasmtime_limits_t *limits, guava_wasmtime_buffer_t *error);

guava_wasmtime_status_t guava_wasmtime_invoke_component(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *export_name, const uint8_t *const *arguments,
    const size_t *argument_sizes, size_t argument_count,
    const char *const *expected_imports, size_t expected_import_count,
    guava_wasmtime_query_callback_t query_callback, void *query_environment,
    const guava_wasmtime_limits_t *limits, guava_wasmtime_buffer_t *output,
    guava_wasmtime_buffer_t *error);

/// Converts component text format to a binary. This is used by deterministic
/// bridge tests and never accepts plugin input in the production path.
guava_wasmtime_status_t guava_wasmtime_component_wat2wasm(
    const uint8_t *wat, size_t wat_size, guava_wasmtime_buffer_t *output,
    guava_wasmtime_buffer_t *error);

int32_t guava_wasmtime_buffer_copy(guava_wasmtime_buffer_t *buffer,
                                   const uint8_t *bytes, size_t size);

void guava_wasmtime_buffer_delete(guava_wasmtime_buffer_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
