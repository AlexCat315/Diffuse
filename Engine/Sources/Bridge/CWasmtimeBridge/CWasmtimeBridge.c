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

typedef struct guava_signature_builder {
  char *data;
  size_t size;
  size_t capacity;
} guava_signature_builder_t;

static void signature_builder_delete(guava_signature_builder_t *builder) {
  if (builder == NULL) {
    return;
  }
  free(builder->data);
  builder->data = NULL;
  builder->size = 0;
  builder->capacity = 0;
}

static bool signature_append(guava_signature_builder_t *builder,
                             const char *bytes, size_t size) {
  if (builder == NULL || (bytes == NULL && size > 0) ||
      size > 64ULL * 1024ULL || builder->size > 64ULL * 1024ULL - size) {
    return false;
  }
  size_t required = builder->size + size + 1;
  if (required > builder->capacity) {
    size_t capacity = builder->capacity == 0 ? 128 : builder->capacity;
    while (capacity < required) {
      if (capacity > 64ULL * 1024ULL / 2) {
        capacity = 64ULL * 1024ULL + 1;
        break;
      }
      capacity *= 2;
    }
    if (capacity > 64ULL * 1024ULL + 1) {
      return false;
    }
    char *resized = (char *)realloc(builder->data, capacity);
    if (resized == NULL) {
      return false;
    }
    builder->data = resized;
    builder->capacity = capacity;
  }
  if (size > 0) {
    memcpy(builder->data + builder->size, bytes, size);
  }
  builder->size += size;
  builder->data[builder->size] = '\0';
  return true;
}

static bool signature_literal(guava_signature_builder_t *builder,
                              const char *literal) {
  return signature_append(builder, literal, strlen(literal));
}

static bool append_type_signature(const wasmtime_component_valtype_t *type,
                                  guava_signature_builder_t *builder,
                                  size_t depth) {
  if (type == NULL || builder == NULL || depth > 12) {
    return false;
  }
  switch (type->kind) {
  case WASMTIME_COMPONENT_VALTYPE_BOOL:
    return signature_literal(builder, "bool");
  case WASMTIME_COMPONENT_VALTYPE_STRING:
    return signature_literal(builder, "string");
  case WASMTIME_COMPONENT_VALTYPE_CHAR:
    return signature_literal(builder, "char");
  case WASMTIME_COMPONENT_VALTYPE_U8:
    return signature_literal(builder, "u8");
  case WASMTIME_COMPONENT_VALTYPE_U16:
    return signature_literal(builder, "u16");
  case WASMTIME_COMPONENT_VALTYPE_U32:
    return signature_literal(builder, "u32");
  case WASMTIME_COMPONENT_VALTYPE_S8:
    return signature_literal(builder, "s8");
  case WASMTIME_COMPONENT_VALTYPE_S16:
    return signature_literal(builder, "s16");
  case WASMTIME_COMPONENT_VALTYPE_S32:
    return signature_literal(builder, "s32");
  case WASMTIME_COMPONENT_VALTYPE_F32:
    return signature_literal(builder, "f32");
  case WASMTIME_COMPONENT_VALTYPE_F64:
    return signature_literal(builder, "f64");
  case WASMTIME_COMPONENT_VALTYPE_LIST: {
    wasmtime_component_valtype_t child = {0};
    wasmtime_component_list_type_element(type->of.list, &child);
    bool valid = signature_literal(builder, "list<") &&
                 append_type_signature(&child, builder, depth + 1) &&
                 signature_literal(builder, ">");
    wasmtime_component_valtype_delete(&child);
    return valid;
  }
  case WASMTIME_COMPONENT_VALTYPE_OPTION: {
    wasmtime_component_valtype_t child = {0};
    wasmtime_component_option_type_ty(type->of.option, &child);
    bool valid = signature_literal(builder, "option<") &&
                 append_type_signature(&child, builder, depth + 1) &&
                 signature_literal(builder, ">");
    wasmtime_component_valtype_delete(&child);
    return valid;
  }
  case WASMTIME_COMPONENT_VALTYPE_RECORD: {
    size_t count = wasmtime_component_record_type_field_count(type->of.record);
    if (count > 64 || !signature_literal(builder, "record{")) {
      return false;
    }
    for (size_t index = 0; index < count; index++) {
      const char *name = NULL;
      size_t name_size = 0;
      wasmtime_component_valtype_t child = {0};
      if (!wasmtime_component_record_type_field_nth(
              type->of.record, index, &name, &name_size, &child)) {
        return false;
      }
      bool valid = (index == 0 || signature_literal(builder, ",")) &&
                   signature_append(builder, name, name_size) &&
                   signature_literal(builder, ":") &&
                   append_type_signature(&child, builder, depth + 1);
      wasmtime_component_valtype_delete(&child);
      if (!valid) {
        return false;
      }
    }
    return signature_literal(builder, "}");
  }
  case WASMTIME_COMPONENT_VALTYPE_ENUM: {
    size_t count = wasmtime_component_enum_type_names_count(type->of.enum_);
    if (count == 0 || count > 128 || !signature_literal(builder, "enum{")) {
      return false;
    }
    for (size_t index = 0; index < count; index++) {
      const char *name = NULL;
      size_t name_size = 0;
      if (!wasmtime_component_enum_type_names_nth(type->of.enum_, index, &name,
                                                   &name_size) ||
          (index > 0 && !signature_literal(builder, ",")) ||
          !signature_append(builder, name, name_size)) {
        return false;
      }
    }
    return signature_literal(builder, "}");
  }
  default:
    return false;
  }
}

static bool validate_capability_function(
    const wasmtime_component_func_type_t *function, const char *name,
    const char *expected_signature, guava_wasmtime_buffer_t *error) {
  if (wasmtime_component_func_type_async(function) ||
      wasmtime_component_func_type_param_count(function) != 1) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s must be synchronous with one input", name);
    return false;
  }
  const char *parameter_name = NULL;
  size_t parameter_name_size = 0;
  wasmtime_component_valtype_t input_type = {0};
  if (!wasmtime_component_func_type_param_nth(
          function, 0, &parameter_name, &parameter_name_size, &input_type) ||
      !bytes_equal(parameter_name, parameter_name_size, "input")) {
    wasmtime_component_valtype_delete(&input_type);
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s parameter must be named input", name);
    return false;
  }
  guava_signature_builder_t signature = {0};
  bool valid = append_type_signature(&input_type, &signature, 0) &&
               expected_signature != NULL && signature.data != NULL &&
               strcmp(signature.data, expected_signature) == 0;
  wasmtime_component_valtype_delete(&input_type);
  signature_builder_delete(&signature);
  if (!valid) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s input type does not match capabilities.wit",
                    name);
    return false;
  }
  wasmtime_component_valtype_t result = {0};
  if (!wasmtime_component_func_type_result(function, &result)) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s must return string", name);
    return false;
  }
  valid = result.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
  wasmtime_component_valtype_delete(&result);
  if (!valid) {
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s must return string", name);
  }
  return valid;
}

static guava_wasmtime_status_t validate_contract(
    guava_wasmtime_runtime_t *runtime, const wasmtime_component_t *component,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
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
  if (wasmtime_component_type_export_count(type, runtime->engine) != 1) {
    wasmtime_component_type_delete(type);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "component must export exactly the capabilities interface");
  }
  wasmtime_component_item_t capabilities = {0};
  bool has_capabilities = wasmtime_component_type_export_get(
      type, runtime->engine, "capabilities", strlen("capabilities"),
      &capabilities);
  if (!has_capabilities ||
      capabilities.kind != WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
    if (has_capabilities) {
      wasmtime_component_item_delete(&capabilities);
    }
    wasmtime_component_type_delete(type);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "component is missing capabilities interface export");
  }
  const wasmtime_component_instance_type_t *instance =
      capabilities.of.component_instance;
  if (wasmtime_component_instance_type_export_count(instance,
                                                     runtime->engine) !=
      expected_capability_count) {
    wasmtime_component_item_delete(&capabilities);
    wasmtime_component_type_delete(type);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "Component capability count does not match capabilities.wit");
  }
  for (size_t index = 0; index < expected_capability_count; index++) {
    const char *name = expected_capabilities[index];
    const char *signature = expected_type_signatures[index];
    if (name == NULL || signature == NULL) {
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                       "expected capability metadata is null");
    }
    wasmtime_component_item_t function = {0};
    bool has_function = wasmtime_component_instance_type_export_get(
        instance, runtime->engine, name, strlen(name), &function);
    if (!has_function ||
        function.kind != WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC ||
        !validate_capability_function(function.of.component_func, name,
                                      signature, error)) {
      if (has_function) {
        wasmtime_component_item_delete(&function);
      }
      if (error == NULL || error->size == 0) {
        (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                        "component is missing typed capability %s", name);
      }
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return GUAVA_WASMTIME_CONTRACT_MISMATCH;
    }
    wasmtime_component_item_delete(&function);
  }
  wasmtime_component_item_delete(&capabilities);
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

typedef struct guava_typed_cursor {
  const uint8_t *data;
  size_t size;
  size_t offset;
} guava_typed_cursor_t;

static bool cursor_read(guava_typed_cursor_t *cursor, void *output,
                        size_t size) {
  if (cursor == NULL || output == NULL || size > cursor->size ||
      cursor->offset > cursor->size - size) {
    return false;
  }
  memcpy(output, cursor->data + cursor->offset, size);
  cursor->offset += size;
  return true;
}

static bool cursor_u8(guava_typed_cursor_t *cursor, uint8_t *output) {
  return cursor_read(cursor, output, 1);
}

static bool cursor_u16(guava_typed_cursor_t *cursor, uint16_t *output) {
  uint8_t bytes[2];
  if (!cursor_read(cursor, bytes, sizeof(bytes))) {
    return false;
  }
  *output = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
  return true;
}

static bool cursor_u32(guava_typed_cursor_t *cursor, uint32_t *output) {
  uint8_t bytes[4];
  if (!cursor_read(cursor, bytes, sizeof(bytes))) {
    return false;
  }
  *output = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
            ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
  return true;
}

static bool cursor_u64(guava_typed_cursor_t *cursor, uint64_t *output) {
  uint8_t bytes[8];
  if (!cursor_read(cursor, bytes, sizeof(bytes))) {
    return false;
  }
  uint64_t value = 0;
  for (size_t index = 0; index < sizeof(bytes); index++) {
    value |= (uint64_t)bytes[index] << (index * 8);
  }
  *output = value;
  return true;
}

static bool valid_unicode_scalar(uint32_t value) {
  return value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff);
}

static bool decode_typed_value(guava_typed_cursor_t *cursor,
                               const wasmtime_component_valtype_t *type,
                               wasmtime_component_val_t *output,
                               size_t depth,
                               guava_wasmtime_buffer_t *error) {
  if (cursor == NULL || type == NULL || output == NULL || depth > 12) {
    (void)set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                    "typed capability input exceeds its nesting limit");
    return false;
  }
  memset(output, 0, sizeof(*output));
  switch (type->kind) {
  case WASMTIME_COMPONENT_VALTYPE_BOOL: {
    uint8_t value = 0;
    if (!cursor_u8(cursor, &value) || value > 1) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_BOOL;
    output->of.boolean = value != 0;
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_U8: {
    uint8_t value = 0;
    if (!cursor_u8(cursor, &value)) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_U8;
    output->of.u8 = value;
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_S8: {
    uint8_t value = 0;
    if (!cursor_u8(cursor, &value)) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_S8;
    output->of.s8 = (int8_t)value;
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_U16:
  case WASMTIME_COMPONENT_VALTYPE_S16: {
    uint16_t value = 0;
    if (!cursor_u16(cursor, &value)) {
      break;
    }
    if (type->kind == WASMTIME_COMPONENT_VALTYPE_U16) {
      output->kind = WASMTIME_COMPONENT_U16;
      output->of.u16 = value;
    } else {
      output->kind = WASMTIME_COMPONENT_S16;
      output->of.s16 = (int16_t)value;
    }
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_U32:
  case WASMTIME_COMPONENT_VALTYPE_S32:
  case WASMTIME_COMPONENT_VALTYPE_CHAR:
  case WASMTIME_COMPONENT_VALTYPE_F32: {
    uint32_t value = 0;
    if (!cursor_u32(cursor, &value)) {
      break;
    }
    if (type->kind == WASMTIME_COMPONENT_VALTYPE_U32) {
      output->kind = WASMTIME_COMPONENT_U32;
      output->of.u32 = value;
    } else if (type->kind == WASMTIME_COMPONENT_VALTYPE_S32) {
      output->kind = WASMTIME_COMPONENT_S32;
      output->of.s32 = (int32_t)value;
    } else if (type->kind == WASMTIME_COMPONENT_VALTYPE_CHAR) {
      if (!valid_unicode_scalar(value)) {
        break;
      }
      output->kind = WASMTIME_COMPONENT_CHAR;
      output->of.character = value;
    } else {
      output->kind = WASMTIME_COMPONENT_F32;
      memcpy(&output->of.f32, &value, sizeof(value));
    }
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_F64: {
    uint64_t value = 0;
    if (!cursor_u64(cursor, &value)) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_F64;
    memcpy(&output->of.f64, &value, sizeof(value));
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_STRING: {
    uint32_t size = 0;
    if (!cursor_u32(cursor, &size) || size > cursor->size ||
        cursor->offset > cursor->size - size) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_STRING;
    wasm_name_new(&output->of.string, size,
                  (const char *)(cursor->data + cursor->offset));
    cursor->offset += size;
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_ENUM: {
    uint32_t index = 0;
    size_t count = wasmtime_component_enum_type_names_count(type->of.enum_);
    const char *name = NULL;
    size_t name_size = 0;
    if (!cursor_u32(cursor, &index) || index >= count || count > 128 ||
        !wasmtime_component_enum_type_names_nth(type->of.enum_, index, &name,
                                                &name_size)) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_ENUM;
    wasm_name_new(&output->of.enumeration, name_size, name);
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_OPTION: {
    uint8_t present = 0;
    if (!cursor_u8(cursor, &present) || present > 1) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_OPTION;
    output->of.option = NULL;
    if (present == 0) {
      return true;
    }
    wasmtime_component_valtype_t child = {0};
    wasmtime_component_option_type_ty(type->of.option, &child);
    wasmtime_component_val_t value = {0};
    bool valid = decode_typed_value(cursor, &child, &value, depth + 1, error);
    wasmtime_component_valtype_delete(&child);
    if (!valid) {
      wasmtime_component_val_delete(&value);
      return false;
    }
    output->of.option = wasmtime_component_val_new(&value);
    if (output->of.option == NULL) {
      wasmtime_component_val_delete(&value);
      (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate typed option value");
      return false;
    }
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_LIST: {
    uint32_t count = 0;
    if (!cursor_u32(cursor, &count) || count > 4096) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_LIST;
    wasmtime_component_vallist_new_uninit(&output->of.list, count);
    if (count > 0 && output->of.list.data == NULL) {
      (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate typed list");
      return false;
    }
    if (count > 0) {
      memset(output->of.list.data, 0,
             count * sizeof(*output->of.list.data));
    }
    wasmtime_component_valtype_t child = {0};
    wasmtime_component_list_type_element(type->of.list, &child);
    for (size_t index = 0; index < count; index++) {
      if (!decode_typed_value(cursor, &child, &output->of.list.data[index],
                              depth + 1, error)) {
        wasmtime_component_valtype_delete(&child);
        return false;
      }
    }
    wasmtime_component_valtype_delete(&child);
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_RECORD: {
    size_t count = wasmtime_component_record_type_field_count(type->of.record);
    if (count > 64) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_RECORD;
    wasmtime_component_valrecord_new_uninit(&output->of.record, count);
    if (count > 0 && output->of.record.data == NULL) {
      (void)set_error(error, GUAVA_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate typed record");
      return false;
    }
    if (count > 0) {
      memset(output->of.record.data, 0,
             count * sizeof(*output->of.record.data));
    }
    for (size_t index = 0; index < count; index++) {
      const char *name = NULL;
      size_t name_size = 0;
      wasmtime_component_valtype_t child = {0};
      if (!wasmtime_component_record_type_field_nth(
              type->of.record, index, &name, &name_size, &child)) {
        return false;
      }
      wasm_name_new(&output->of.record.data[index].name, name_size, name);
      bool valid = decode_typed_value(
          cursor, &child, &output->of.record.data[index].val, depth + 1, error);
      wasmtime_component_valtype_delete(&child);
      if (!valid) {
        return false;
      }
    }
    return true;
  }
  default:
    (void)set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                    "Component capability uses an unsupported typed value");
    return false;
  }
  (void)set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                  "typed capability input is truncated or malformed");
  return false;
}

guava_wasmtime_status_t guava_wasmtime_validate_component(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
    const guava_wasmtime_limits_t *limits, guava_wasmtime_buffer_t *error) {
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (runtime == NULL || component_path == NULL ||
      (expected_import_count > 0 && expected_imports == NULL) ||
      (expected_capability_count > 0 &&
       (expected_capabilities == NULL || expected_type_signatures == NULL)) ||
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
                             expected_import_count, expected_capabilities,
                             expected_type_signatures,
                             expected_capability_count, error);
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

guava_wasmtime_status_t guava_wasmtime_invoke_capability(
    guava_wasmtime_runtime_t *runtime, const char *component_path,
    const char *capability_name, const uint8_t *typed_input,
    size_t typed_input_size,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
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
  if (runtime == NULL || component_path == NULL || capability_name == NULL ||
      output == NULL || !valid_limits(limits) ||
      typed_input == NULL || typed_input_size < 4 ||
      typed_input_size > limits->maximum_output_bytes ||
      (expected_import_count > 0 && expected_imports == NULL) ||
      (expected_capability_count > 0 &&
       (expected_capabilities == NULL || expected_type_signatures == NULL))) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "invalid Component invocation arguments");
  }
  bool declared = false;
  for (size_t index = 0; index < expected_capability_count; index++) {
    if (expected_capabilities[index] != NULL &&
        strcmp(expected_capabilities[index], capability_name) == 0) {
      declared = true;
      break;
    }
  }
  if (!declared) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "capability is absent from capabilities.wit");
  }
  const uint8_t magic[] = {0x47, 0x54, 0x56, 0x31};
  if (memcmp(typed_input, magic, sizeof(magic)) != 0) {
    return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                     "typed capability input has an unsupported version");
  }
  wasmtime_component_t *component = NULL;
  guava_wasmtime_status_t status =
      compile_component(runtime, component_path, &component, error);
  if (status != GUAVA_WASMTIME_OK) {
    return status;
  }
  status = validate_contract(runtime, component, expected_imports,
                             expected_import_count, expected_capabilities,
                             expected_type_signatures,
                             expected_capability_count, error);
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
  wasmtime_component_export_index_t *capabilities_index =
      wasmtime_component_get_export_index(component, NULL, "capabilities",
                                          strlen("capabilities"));
  wasmtime_component_export_index_t *function_index = capabilities_index == NULL
      ? NULL
      : wasmtime_component_get_export_index(
            component, capabilities_index, capability_name,
            strlen(capability_name));
  wasmtime_component_func_t function;
  if (function_index == NULL ||
      !wasmtime_component_instance_get_func(&instance, context, function_index,
                                            &function)) {
    if (function_index != NULL) {
      wasmtime_component_export_index_delete(function_index);
    }
    if (capabilities_index != NULL) {
      wasmtime_component_export_index_delete(capabilities_index);
    }
    wasmtime_store_delete(store);
    wasmtime_component_delete(component);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "validated typed capability could not be resolved");
  }
  wasmtime_component_export_index_delete(function_index);
  wasmtime_component_export_index_delete(capabilities_index);

  wasmtime_component_func_type_t *function_type =
      wasmtime_component_func_type(&function, context);
  const char *parameter_name = NULL;
  size_t parameter_name_size = 0;
  wasmtime_component_valtype_t input_type = {0};
  if (function_type == NULL ||
      !wasmtime_component_func_type_param_nth(
          function_type, 0, &parameter_name, &parameter_name_size,
          &input_type)) {
    if (function_type != NULL) {
      wasmtime_component_func_type_delete(function_type);
    }
    wasmtime_store_delete(store);
    wasmtime_component_delete(component);
    return set_error(error, GUAVA_WASMTIME_CONTRACT_MISMATCH,
                     "could not reflect typed capability input");
  }
  wasmtime_component_func_type_delete(function_type);
  guava_typed_cursor_t cursor = {
      .data = typed_input,
      .size = typed_input_size,
      .offset = sizeof(magic),
  };
  wasmtime_component_val_t component_argument = {0};
  bool decoded = decode_typed_value(&cursor, &input_type,
                                    &component_argument, 0, error);
  wasmtime_component_valtype_delete(&input_type);
  if (!decoded || cursor.offset != cursor.size) {
    wasmtime_component_val_delete(&component_argument);
    wasmtime_store_delete(store);
    wasmtime_component_delete(component);
    if (error == NULL || error->size == 0) {
      return set_error(error, GUAVA_WASMTIME_INVALID_ARGUMENT,
                       "typed capability input has trailing or invalid bytes");
    }
    return GUAVA_WASMTIME_INVALID_ARGUMENT;
  }
  wasmtime_component_val_t result = {0};
  wasmtime_error_t *wasmtime_error = wasmtime_component_func_call(
      &function, context, &component_argument, 1, &result, 1);
  wasmtime_component_val_delete(&component_argument);
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
