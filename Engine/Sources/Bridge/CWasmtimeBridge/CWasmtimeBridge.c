#include "CWasmtimeBridge.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wasm.h>
#include <wasmtime.h>
#include <wasmtime/component.h>

#define GUAVA_MAX_COMPONENT_BYTES (128ULL * 1024ULL * 1024ULL)

struct guava_wasmtime_runtime {
  wasm_engine_t *engine;
};

typedef struct guava_host_binding {
  uint8_t *interface_name;
  size_t interface_name_size;
  guava_wasmtime_query_callback_t callback;
  void *environment;
  size_t maximum_output_bytes;
  size_t maximum_query_request_bytes;
} guava_host_binding_t;

static guava_wasmtime_status_t
set_error(guava_wasmtime_buffer_t *error, guava_wasmtime_status_t status,
          const char *format, ...) {
  if (error == NULL) {
    return status;
  }
  va_list arguments;
  va_start(arguments, format);
  va_list copied;
  va_copy(copied, arguments);
  int required = vsnprintf(NULL, 0, format, copied);
  va_end(copied);
  if (required < 0) {
    va_end(arguments);
    return status;
  }
  uint8_t *bytes = (uint8_t *)malloc((size_t)required);
  if (bytes == NULL && required > 0) {
    va_end(arguments);
    return GUAVA_WASMTIME_OUT_OF_MEMORY;
  }
  if (required > 0) {
    char *terminated = (char *)malloc((size_t)required + 1);
    if (terminated == NULL) {
      free(bytes);
      va_end(arguments);
      return GUAVA_WASMTIME_OUT_OF_MEMORY;
    }
    (void)vsnprintf(terminated, (size_t)required + 1, format, arguments);
    memcpy(bytes, terminated, (size_t)required);
    free(terminated);
  }
  va_end(arguments);
  guava_wasmtime_buffer_delete(error);
  error->data = bytes;
  error->size = (size_t)required;
  return status;
}

static guava_wasmtime_status_t
take_wasmtime_error(wasmtime_error_t *wasmtime_error,
                    guava_wasmtime_status_t status,
                    guava_wasmtime_buffer_t *error) {
  if (wasmtime_error == NULL) {
    return status;
  }
  wasm_name_t message;
  wasmtime_error_message(wasmtime_error, &message);
  if (error != NULL) {
    (void)guava_wasmtime_buffer_copy(error, (const uint8_t *)message.data,
                                     message.size);
  }
  wasm_name_delete(&message);
  wasmtime_error_delete(wasmtime_error);
  return status;
}

int32_t guava_wasmtime_buffer_copy(guava_wasmtime_buffer_t *buffer,
                                   const uint8_t *bytes, size_t size) {
  if (buffer == NULL || (bytes == NULL && size > 0)) {
    return -1;
  }
  uint8_t *copy = NULL;
  if (size > 0) {
    copy = (uint8_t *)malloc(size);
    if (copy == NULL) {
      return -1;
    }
    memcpy(copy, bytes, size);
  }
  guava_wasmtime_buffer_delete(buffer);
  buffer->data = copy;
  buffer->size = size;
  return 0;
}

void guava_wasmtime_buffer_delete(guava_wasmtime_buffer_t *buffer) {
  if (buffer == NULL) {
    return;
  }
  free(buffer->data);
  buffer->data = NULL;
  buffer->size = 0;
}

const char *guava_wasmtime_runtime_version(void) { return "45.0.0"; }

guava_wasmtime_runtime_t *
guava_wasmtime_runtime_new(guava_wasmtime_buffer_t *error) {
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  wasm_config_t *config = wasm_config_new();
  if (config == NULL) {
    (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Wasmtime configuration");
    return NULL;
  }
  wasmtime_config_consume_fuel_set(config, true);
  wasmtime_config_epoch_interruption_set(config, true);
  wasmtime_config_wasm_component_model_set(config, true);
  wasm_engine_t *engine = wasm_engine_new_with_config(config);
  if (engine == NULL) {
    (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                    "could not create Wasmtime engine");
    return NULL;
  }
  guava_wasmtime_runtime_t *runtime =
      (guava_wasmtime_runtime_t *)calloc(1, sizeof(*runtime));
  if (runtime == NULL) {
    wasm_engine_delete(engine);
    (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Guava Wasmtime runtime");
    return NULL;
  }
  runtime->engine = engine;
  return runtime;
}

void guava_wasmtime_runtime_delete(guava_wasmtime_runtime_t *runtime) {
  if (runtime == NULL) {
    return;
  }
  wasm_engine_delete(runtime->engine);
  free(runtime);
}

void guava_wasmtime_runtime_interrupt(guava_wasmtime_runtime_t *runtime) {
  if (runtime != NULL && runtime->engine != NULL) {
    wasmtime_engine_increment_epoch(runtime->engine);
  }
}

static guava_wasmtime_status_t
read_component(const char *path, uint8_t **bytes_out, size_t *size_out,
               guava_wasmtime_buffer_t *error) {
  if (path == NULL || bytes_out == NULL || size_out == NULL) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "invalid component path");
  }
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    return set_error(error, GUAVA_WASMTIME_IO_ERROR,
                     "could not open component.wasm");
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return set_error(error, GUAVA_WASMTIME_IO_ERROR,
                     "could not measure component.wasm");
  }
  long measured = ftell(file);
  if (measured < 0 || (uint64_t)measured > GUAVA_MAX_COMPONENT_BYTES) {
    fclose(file);
    return set_error(error, GUAVA_WASMTIME_IO_ERROR,
                     "component.wasm exceeds 128 MiB");
  }
  if (fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return set_error(error, GUAVA_WASMTIME_IO_ERROR,
                     "could not rewind component.wasm");
  }
  size_t size = (size_t)measured;
  uint8_t *bytes = size == 0 ? NULL : (uint8_t *)malloc(size);
  if (bytes == NULL && size > 0) {
    fclose(file);
    return set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                     "could not allocate component buffer");
  }
  if (size > 0 && fread(bytes, 1, size, file) != size) {
    free(bytes);
    fclose(file);
    return set_error(error, GUAVA_WASMTIME_IO_ERROR,
                     "could not read complete component.wasm");
  }
  fclose(file);
  *bytes_out = bytes;
  *size_out = size;
  return GUAVA_WASMTIME_OK;
}

static guava_wasmtime_status_t
compile_component(guava_wasmtime_runtime_t *runtime, const char *path,
                  wasmtime_component_t **component_out,
                  guava_wasmtime_buffer_t *error) {
  uint8_t *bytes = NULL;
  size_t size = 0;
  guava_wasmtime_status_t status =
      read_component(path, &bytes, &size, error);
  if (status != GUAVA_WASMTIME_OK) {
    return status;
  }
  wasmtime_error_t *wasmtime_error = wasmtime_component_new(
      runtime->engine, bytes, size, component_out);
  free(bytes);
  if (wasmtime_error != NULL) {
    return take_wasmtime_error(wasmtime_error, GUAVA_WASMTIME_COMPILE_ERROR,
                               error);
  }
  return GUAVA_WASMTIME_OK;
}

static bool bytes_equal(const char *bytes, size_t size, const char *expected) {
  size_t expected_size = strlen(expected);
  return size == expected_size && memcmp(bytes, expected, size) == 0;
}

static bool validate_string_function(
    const wasmtime_component_func_type_t *function,
    const char *const *parameter_names, size_t parameter_count,
    guava_wasmtime_buffer_t *error, const char *display_name) {
  if (wasmtime_component_func_type_async(function)) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "%s must be synchronous", display_name);
    return false;
  }
  if (wasmtime_component_func_type_param_count(function) != parameter_count) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "%s has the wrong parameter count", display_name);
    return false;
  }
  for (size_t index = 0; index < parameter_count; index++) {
    const char *name = NULL;
    size_t name_size = 0;
    wasmtime_component_valtype_t type;
    if (!wasmtime_component_func_type_param_nth(function, index, &name,
                                                &name_size, &type)) {
      (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                      "%s parameter reflection failed", display_name);
      return false;
    }
    bool valid = type.kind == WASMTIME_COMPONENT_VALTYPE_STRING &&
                 bytes_equal(name, name_size, parameter_names[index]);
    wasmtime_component_valtype_delete(&type);
    if (!valid) {
      (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                      "%s parameters must exactly match the Guava string ABI",
                      display_name);
      return false;
    }
  }
  wasmtime_component_valtype_t result;
  if (!wasmtime_component_func_type_result(function, &result)) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "%s must return string", display_name);
    return false;
  }
  bool valid_result = result.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
  wasmtime_component_valtype_delete(&result);
  if (!valid_result) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "%s must return string", display_name);
    return false;
  }
  return true;
}

static bool validate_query_import(const wasmtime_component_item_t *item,
                                  guava_wasmtime_runtime_t *runtime,
                                  const char *import_name,
                                  guava_wasmtime_buffer_t *error) {
  if (item->kind != WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "import %s must be a component interface", import_name);
    return false;
  }
  const wasmtime_component_instance_type_t *instance =
      item->of.component_instance;
  if (wasmtime_component_instance_type_export_count(instance, runtime->engine) !=
      1) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "import %s must expose only query", import_name);
    return false;
  }
  wasmtime_component_item_t query;
  if (!wasmtime_component_instance_type_export_get(
          instance, runtime->engine, "query", strlen("query"), &query)) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "import %s is missing query", import_name);
    return false;
  }
  bool valid = query.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC;
  if (valid) {
    const char *parameter_names[] = {"request"};
    char display_name[256];
    (void)snprintf(display_name, sizeof(display_name), "%s.query",
                   import_name);
    valid = validate_string_function(query.of.component_func, parameter_names,
                                     1, error, display_name);
  } else {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "import %s query must be a function", import_name);
  }
  wasmtime_component_item_delete(&query);
  return valid;
}

static bool validate_export(const wasmtime_component_type_t *component_type,
                            guava_wasmtime_runtime_t *runtime,
                            const char *name,
                            const char *const *parameter_names,
                            size_t parameter_count,
                            guava_wasmtime_buffer_t *error) {
  wasmtime_component_item_t item;
  if (!wasmtime_component_type_export_get(component_type, runtime->engine,
                                          name, strlen(name), &item)) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "component is missing export %s", name);
    return false;
  }
  bool valid = item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC;
  if (valid) {
    valid = validate_string_function(item.of.component_func, parameter_names,
                                     parameter_count, error, name);
  } else {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "export %s must be a component function", name);
  }
  wasmtime_component_item_delete(&item);
  return valid;
}

static guava_wasmtime_status_t validate_contract(
    guava_wasmtime_runtime_t *runtime, const wasmtime_component_t *component,
    const char *const *expected_imports, size_t expected_import_count,
    guava_wasmtime_buffer_t *error) {
  wasmtime_component_type_t *type = wasmtime_component_type(component);
  if (type == NULL) {
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "could not reflect component type");
  }
  if (wasmtime_component_type_import_count(type, runtime->engine) !=
      expected_import_count) {
    wasmtime_component_type_delete(type);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "component imports do not match capabilities.wit");
  }
  for (size_t index = 0; index < expected_import_count; index++) {
    const char *name = expected_imports[index];
    if (name == NULL) {
      wasmtime_component_type_delete(type);
      return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                       "expected import name is null");
    }
    wasmtime_component_item_t item;
    if (!wasmtime_component_type_import_get(type, runtime->engine, name,
                                            strlen(name), &item)) {
      wasmtime_component_type_delete(type);
      return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                       "component is missing declared import %s", name);
    }
    bool valid = validate_query_import(&item, runtime, name, error);
    wasmtime_component_item_delete(&item);
    if (!valid) {
      wasmtime_component_type_delete(type);
      return GUAVA_WASMTIME_CONTRACT_MISMATCH;
    }
  }
  if (wasmtime_component_type_export_count(type, runtime->engine) != 2) {
    wasmtime_component_type_delete(type);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "component must export exactly discover and prepare");
  }
  if (!validate_export(type, runtime, "discover", NULL, 0, error)) {
    wasmtime_component_type_delete(type);
    return GUAVA_WASMTIME_CONTRACT_MISMATCH;
  }
  const char *prepare_parameters[] = {"capability-id", "input"};
  if (!validate_export(type, runtime, "prepare", prepare_parameters, 2,
                       error)) {
    wasmtime_component_type_delete(type);
    return GUAVA_WASMTIME_CONTRACT_MISMATCH;
  }
  wasmtime_component_type_delete(type);
  return GUAVA_WASMTIME_OK;
}

static wasmtime_store_t *
make_store(guava_wasmtime_runtime_t *runtime,
           const guava_wasmtime_limits_t *limits,
           guava_wasmtime_buffer_t *error) {
  wasmtime_store_t *store = wasmtime_store_new(runtime->engine, NULL, NULL);
  if (store == NULL) {
    (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Wasmtime store");
    return NULL;
  }
  wasmtime_store_limiter(store, (int64_t)limits->maximum_memory_bytes,
                         limits->maximum_table_elements,
                         limits->maximum_instances, limits->maximum_tables,
                         limits->maximum_memories);
  wasmtime_context_t *context = wasmtime_store_context(store);
  wasmtime_error_t *wasmtime_error =
      wasmtime_context_set_fuel(context, limits->fuel_per_invocation);
  if (wasmtime_error != NULL) {
    (void)take_wasmtime_error(wasmtime_error,
                              GUAVA_WASMTIME_INVOCATION_ERROR, error);
    wasmtime_store_delete(store);
    return NULL;
  }
  // One engine epoch advancement interrupts this invocation. Swift schedules
  // the wall-clock deadline and calls guava_wasmtime_runtime_interrupt.
  wasmtime_context_set_epoch_deadline(context, 1);
  return store;
}

static void delete_host_binding(void *opaque) {
  guava_host_binding_t *binding = (guava_host_binding_t *)opaque;
  if (binding == NULL) {
    return;
  }
  free(binding->interface_name);
  free(binding);
}

static char *terminated_copy(const uint8_t *bytes, size_t size,
                             const char *fallback) {
  const uint8_t *source = bytes;
  size_t source_size = size;
  if (source == NULL || source_size == 0) {
    source = (const uint8_t *)fallback;
    source_size = strlen(fallback);
  }
  char *result = (char *)malloc(source_size + 1);
  if (result == NULL) {
    return NULL;
  }
  memcpy(result, source, source_size);
  result[source_size] = '\0';
  return result;
}

static wasmtime_error_t *host_query_callback(
    void *opaque, wasmtime_context_t *context,
    const wasmtime_component_func_type_t *type, wasmtime_component_val_t *args,
    size_t argument_count, wasmtime_component_val_t *results,
    size_t result_count) {
  (void)context;
  (void)type;
  guava_host_binding_t *binding = (guava_host_binding_t *)opaque;
  if (binding == NULL || binding->callback == NULL) {
    return wasmtime_error_new("Guava query context is unavailable");
  }
  if (argument_count != 1 || result_count != 1 ||
      args[0].kind != WASMTIME_COMPONENT_STRING) {
    return wasmtime_error_new("Guava query called with an invalid ABI");
  }
  if (args[0].of.string.size > binding->maximum_query_request_bytes) {
    return wasmtime_error_new("Guava query request exceeds its byte limit");
  }
  guava_wasmtime_buffer_t response = {0};
  guava_wasmtime_buffer_t callback_error = {0};
  int32_t callback_status = binding->callback(
      binding->environment, binding->interface_name,
      binding->interface_name_size, (const uint8_t *)args[0].of.string.data,
      args[0].of.string.size, &response, &callback_error);
  if (callback_status != 0) {
    char *message = terminated_copy(callback_error.data, callback_error.size,
                                    "Guava query was rejected");
    guava_wasmtime_buffer_delete(&response);
    guava_wasmtime_buffer_delete(&callback_error);
    if (message == NULL) {
      return wasmtime_error_new("Guava query failed without diagnostics");
    }
    wasmtime_error_t *error = wasmtime_error_new(message);
    free(message);
    return error;
  }
  guava_wasmtime_buffer_delete(&callback_error);
  if (response.size > binding->maximum_output_bytes) {
    guava_wasmtime_buffer_delete(&response);
    return wasmtime_error_new("Guava query response exceeds its byte limit");
  }
  results[0].kind = WASMTIME_COMPONENT_STRING;
  wasm_name_new(&results[0].of.string, response.size,
                (const char *)response.data);
  guava_wasmtime_buffer_delete(&response);
  return NULL;
}

static wasmtime_component_linker_t *build_linker(
    guava_wasmtime_runtime_t *runtime, const char *const *expected_imports,
    size_t expected_import_count, guava_wasmtime_query_callback_t callback,
    void *environment, const guava_wasmtime_limits_t *limits,
    guava_wasmtime_buffer_t *error) {
  wasmtime_component_linker_t *linker =
      wasmtime_component_linker_new(runtime->engine);
  if (linker == NULL) {
    (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Component linker");
    return NULL;
  }
  wasmtime_component_linker_instance_t *root =
      wasmtime_component_linker_root(linker);
  if (root == NULL) {
    wasmtime_component_linker_delete(linker);
    (void)set_error(error, GUAVA_WASMTIME_LINK_ERROR,
                    "could not acquire Component linker root");
    return NULL;
  }
  for (size_t index = 0; index < expected_import_count; index++) {
    const char *name = expected_imports[index];
    wasmtime_component_linker_instance_t *child = NULL;
    wasmtime_error_t *wasmtime_error =
        wasmtime_component_linker_instance_add_instance(
            root, name, strlen(name), &child);
    if (wasmtime_error != NULL) {
      wasmtime_component_linker_instance_delete(root);
      wasmtime_component_linker_delete(linker);
      (void)take_wasmtime_error(wasmtime_error, GUAVA_WASMTIME_LINK_ERROR,
                                error);
      return NULL;
    }
    guava_host_binding_t *binding =
        (guava_host_binding_t *)calloc(1, sizeof(*binding));
    if (binding == NULL) {
      wasmtime_component_linker_instance_delete(child);
      wasmtime_component_linker_instance_delete(root);
      wasmtime_component_linker_delete(linker);
      (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate Guava host binding");
      return NULL;
    }
    binding->interface_name_size = strlen(name);
    binding->interface_name =
        (uint8_t *)malloc(binding->interface_name_size);
    if (binding->interface_name == NULL &&
        binding->interface_name_size > 0) {
      free(binding);
      wasmtime_component_linker_instance_delete(child);
      wasmtime_component_linker_instance_delete(root);
      wasmtime_component_linker_delete(linker);
      (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                      "could not copy Guava import name");
      return NULL;
    }
    memcpy(binding->interface_name, name, binding->interface_name_size);
    binding->callback = callback;
    binding->environment = environment;
    binding->maximum_output_bytes = limits->maximum_output_bytes;
    binding->maximum_query_request_bytes =
        limits->maximum_query_request_bytes;
    wasmtime_error = wasmtime_component_linker_instance_add_func(
        child, "query", strlen("query"), host_query_callback, binding,
        delete_host_binding);
    if (wasmtime_error != NULL) {
      delete_host_binding(binding);
      wasmtime_component_linker_instance_delete(child);
      wasmtime_component_linker_instance_delete(root);
      wasmtime_component_linker_delete(linker);
      (void)take_wasmtime_error(wasmtime_error, GUAVA_WASMTIME_LINK_ERROR,
                                error);
      return NULL;
    }
    wasmtime_component_linker_instance_delete(child);
  }
  wasmtime_component_linker_instance_delete(root);
  return linker;
}

static guava_wasmtime_status_t instantiate_component(
    guava_wasmtime_runtime_t *runtime, const wasmtime_component_t *component,
    const char *const *expected_imports, size_t expected_import_count,
    guava_wasmtime_query_callback_t callback, void *environment,
    const guava_wasmtime_limits_t *limits, wasmtime_store_t **store_out,
    wasmtime_component_instance_t *instance_out,
    guava_wasmtime_buffer_t *error) {
  wasmtime_store_t *store = make_store(runtime, limits, error);
  if (store == NULL) {
    return GUAVA_WASMTIME_INVOCATION_ERROR;
  }
  wasmtime_component_linker_t *linker = build_linker(
      runtime, expected_imports, expected_import_count, callback, environment,
      limits, error);
  if (linker == NULL) {
    wasmtime_store_delete(store);
    return GUAVA_WASMTIME_LINK_ERROR;
  }
  wasmtime_error_t *wasmtime_error = wasmtime_component_linker_instantiate(
      linker, wasmtime_store_context(store), component, instance_out);
  wasmtime_component_linker_delete(linker);
  if (wasmtime_error != NULL) {
    wasmtime_store_delete(store);
    return take_wasmtime_error(wasmtime_error, GUAVA_WASMTIME_LINK_ERROR,
                               error);
  }
  *store_out = store;
  return GUAVA_WASMTIME_OK;
}

static bool valid_limits(const guava_wasmtime_limits_t *limits) {
  return limits != NULL && limits->maximum_memory_bytes > 0 &&
         limits->maximum_memory_bytes <= 64ULL * 1024ULL * 1024ULL &&
         limits->fuel_per_invocation > 0 &&
         limits->maximum_output_bytes > 0 &&
         limits->maximum_output_bytes <= 1024ULL * 1024ULL &&
         limits->maximum_query_request_bytes > 0 &&
         limits->maximum_query_request_bytes <= 16ULL * 1024ULL &&
         limits->maximum_instances > 0 && limits->maximum_instances <= 64 &&
         limits->maximum_tables > 0 && limits->maximum_tables <= 16 &&
         limits->maximum_memories > 0 && limits->maximum_memories <= 16 &&
         limits->maximum_table_elements > 0 &&
         limits->maximum_table_elements <= 100000;
}

guava_wasmtime_status_t guava_wasmtime_validate_component(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *const *expected_imports, size_t expected_import_count,
    const guava_wasmtime_limits_t *limits, guava_wasmtime_buffer_t *error) {
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (runtime == NULL || component_path == NULL ||
      (expected_import_count > 0 && expected_imports == NULL) ||
      !valid_limits(limits)) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "invalid Component validation arguments");
  }
  wasmtime_component_t *component = NULL;
  guava_wasmtime_status_t status =
      compile_component(runtime, component_path, &component, error);
  if (status != GUAVA_WASMTIME_OK) {
    return status;
  }
  status = validate_contract(runtime, component, expected_imports,
                             expected_import_count, error);
  if (status == GUAVA_WASMTIME_OK) {
    wasmtime_store_t *store = NULL;
    wasmtime_component_instance_t instance = {0};
    status = instantiate_component(
        runtime, component, expected_imports, expected_import_count, NULL, NULL,
        limits, &store, &instance, error);
    if (store != NULL) {
      wasmtime_store_delete(store);
    }
  }
  wasmtime_component_delete(component);
  return status;
}

guava_wasmtime_status_t guava_wasmtime_invoke_component(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *export_name, const uint8_t *const *arguments,
    const size_t *argument_sizes, size_t argument_count,
    const char *const *expected_imports, size_t expected_import_count,
    guava_wasmtime_query_callback_t query_callback, void *query_environment,
    const guava_wasmtime_limits_t *limits, guava_wasmtime_buffer_t *output,
    guava_wasmtime_buffer_t *error) {
  if (output != NULL) {
    output->data = NULL;
    output->size = 0;
  }
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (runtime == NULL || component_path == NULL || export_name == NULL ||
      output == NULL || !valid_limits(limits) ||
      (argument_count > 0 && (arguments == NULL || argument_sizes == NULL)) ||
      (expected_import_count > 0 && expected_imports == NULL)) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "invalid Component invocation arguments");
  }
  if ((!bytes_equal(export_name, strlen(export_name), "discover") ||
       argument_count != 0) &&
      (!bytes_equal(export_name, strlen(export_name), "prepare") ||
       argument_count != 2)) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "only discover() and prepare(string, string) may run");
  }
  size_t total_input = 0;
  for (size_t index = 0; index < argument_count; index++) {
    if (arguments[index] == NULL && argument_sizes[index] > 0) {
      return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                       "component argument is null");
    }
    if (argument_sizes[index] > limits->maximum_output_bytes ||
        total_input > limits->maximum_output_bytes - argument_sizes[index]) {
      return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                       "component input exceeds 1 MiB");
    }
    total_input += argument_sizes[index];
  }
  wasmtime_component_t *component = NULL;
  guava_wasmtime_status_t status =
      compile_component(runtime, component_path, &component, error);
  if (status != GUAVA_WASMTIME_OK) {
    return status;
  }
  status = validate_contract(runtime, component, expected_imports,
                             expected_import_count, error);
  if (status != GUAVA_WASMTIME_OK) {
    wasmtime_component_delete(component);
    return status;
  }
  wasmtime_store_t *store = NULL;
  wasmtime_component_instance_t instance = {0};
  status = instantiate_component(
      runtime, component, expected_imports, expected_import_count,
      query_callback, query_environment, limits, &store, &instance, error);
  if (status != GUAVA_WASMTIME_OK) {
    wasmtime_component_delete(component);
    return status;
  }
  wasmtime_context_t *context = wasmtime_store_context(store);
  wasmtime_component_export_index_t *export_index =
      wasmtime_component_get_export_index(component, NULL, export_name,
                                          strlen(export_name));
  wasmtime_component_func_t function;
  if (export_index == NULL ||
      !wasmtime_component_instance_get_func(&instance, context, export_index,
                                            &function)) {
    if (export_index != NULL) {
      wasmtime_component_export_index_delete(export_index);
    }
    wasmtime_store_delete(store);
    wasmtime_component_delete(component);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "validated Component export could not be resolved");
  }
  wasmtime_component_export_index_delete(export_index);
  wasmtime_component_val_t *component_arguments = argument_count == 0
      ? NULL
      : (wasmtime_component_val_t *)calloc(argument_count,
                                           sizeof(*component_arguments));
  if (component_arguments == NULL && argument_count > 0) {
    wasmtime_store_delete(store);
    wasmtime_component_delete(component);
    return set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                     "could not allocate Component arguments");
  }
  for (size_t index = 0; index < argument_count; index++) {
    component_arguments[index].kind = WASMTIME_COMPONENT_STRING;
    wasm_name_new(&component_arguments[index].of.string, argument_sizes[index],
                  (const char *)arguments[index]);
  }
  wasmtime_component_val_t result = {0};
  wasmtime_error_t *wasmtime_error = wasmtime_component_func_call(
      &function, context, component_arguments, argument_count, &result, 1);
  for (size_t index = 0; index < argument_count; index++) {
    wasmtime_component_val_delete(&component_arguments[index]);
  }
  free(component_arguments);
  if (wasmtime_error != NULL) {
    status = take_wasmtime_error(wasmtime_error,
                                 GUAVA_WASMTIME_INVOCATION_ERROR, error);
  } else if (result.kind != WASMTIME_COMPONENT_STRING) {
    status = set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                       "Component export returned a non-string value");
  } else if (result.of.string.size > limits->maximum_output_bytes) {
    status = set_error(error, GUAVA_WASMTIME_OUTPUT_TOO_LARGE,
                       "Component output exceeds 1 MiB");
  } else if (guava_wasmtime_buffer_copy(
                 output, (const uint8_t *)result.of.string.data,
                 result.of.string.size) != 0) {
    status = set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                       "could not copy Component output");
  }
  if (wasmtime_error == NULL) {
    wasmtime_component_val_delete(&result);
  }
  wasmtime_store_delete(store);
  wasmtime_component_delete(component);
  return status;
}

guava_wasmtime_status_t guava_wasmtime_component_wat2wasm(
    const uint8_t *wat, size_t wat_size, guava_wasmtime_buffer_t *output,
    guava_wasmtime_buffer_t *error) {
  if (output != NULL) {
    output->data = NULL;
    output->size = 0;
  }
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (wat == NULL || wat_size == 0 || output == NULL) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "component WAT is empty");
  }
  wasm_byte_vec_t binary;
  wasmtime_error_t *wasmtime_error =
      wasmtime_wat2wasm((const char *)wat, wat_size, &binary);
  if (wasmtime_error != NULL) {
    return take_wasmtime_error(wasmtime_error, GUAVA_WASMTIME_COMPILE_ERROR,
                               error);
  }
  guava_wasmtime_status_t status = GUAVA_WASMTIME_OK;
  if (guava_wasmtime_buffer_copy(output, (const uint8_t *)binary.data,
                                 binary.size) != 0) {
    status = set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                       "could not copy compiled component WAT");
  }
  wasm_byte_vec_delete(&binary);
  return status;
}
