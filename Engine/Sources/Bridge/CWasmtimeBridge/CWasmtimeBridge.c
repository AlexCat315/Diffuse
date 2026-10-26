#include "CWasmtimeBridge.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#include <wasm.h>
#include <wasmtime.h>
#include <wasmtime/component.h>

#define COVE_MAX_COMPONENT_BYTES (128ULL * 1024ULL * 1024ULL)
#define COVE_COMPONENT_CACHE_SIZE 16

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef SRWLOCK cove_mutex_t;
static void cove_mutex_init(cove_mutex_t *mutex) { InitializeSRWLock(mutex); }
static void cove_mutex_lock(cove_mutex_t *mutex) { AcquireSRWLockExclusive(mutex); }
static void cove_mutex_unlock(cove_mutex_t *mutex) { ReleaseSRWLockExclusive(mutex); }
static void cove_mutex_destroy(cove_mutex_t *mutex) { (void)mutex; }
#else
#include <pthread.h>
typedef pthread_mutex_t cove_mutex_t;
static void cove_mutex_init(cove_mutex_t *mutex) { pthread_mutex_init(mutex, NULL); }
static void cove_mutex_lock(cove_mutex_t *mutex) { pthread_mutex_lock(mutex); }
static void cove_mutex_unlock(cove_mutex_t *mutex) { pthread_mutex_unlock(mutex); }
static void cove_mutex_destroy(cove_mutex_t *mutex) { pthread_mutex_destroy(mutex); }
#endif

// A compiled Component keyed by its path and exact bytes. Compiling is the
// dominant cost of a call, and every call reads the file again, so a changed
// package never runs stale code.
typedef struct cove_cached_component {
  char *path;
  uint8_t *bytes;
  size_t size;
  wasmtime_component_t *component;
  uint64_t last_use;
} cove_cached_component_t;

struct cove_wasmtime_runtime {
  wasm_engine_t *engine;
  bool interpreter;
  cove_mutex_t cache_lock;
  cove_cached_component_t cache[COVE_COMPONENT_CACHE_SIZE];
  uint64_t cache_clock;
};

typedef struct cove_host_binding {
  uint8_t *interface_name;
  size_t interface_name_size;
  cove_wasmtime_query_callback_t callback;
  void *environment;
  size_t maximum_output_bytes;
  size_t maximum_query_request_bytes;
} cove_host_binding_t;

static cove_wasmtime_status_t
set_error(cove_wasmtime_buffer_t *error, cove_wasmtime_status_t status,
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
    return COVE_WASMTIME_OUT_OF_MEMORY;
  }
  if (required > 0) {
    char *terminated = (char *)malloc((size_t)required + 1);
    if (terminated == NULL) {
      free(bytes);
      va_end(arguments);
      return COVE_WASMTIME_OUT_OF_MEMORY;
    }
    (void)vsnprintf(terminated, (size_t)required + 1, format, arguments);
    memcpy(bytes, terminated, (size_t)required);
    free(terminated);
  }
  va_end(arguments);
  cove_wasmtime_buffer_delete(error);
  error->data = bytes;
  error->size = (size_t)required;
  return status;
}

static cove_wasmtime_status_t
take_wasmtime_error(wasmtime_error_t *wasmtime_error,
                    cove_wasmtime_status_t status,
                    cove_wasmtime_buffer_t *error) {
  if (wasmtime_error == NULL) {
    return status;
  }
  wasm_name_t message;
  wasmtime_error_message(wasmtime_error, &message);
  if (error != NULL) {
    (void)cove_wasmtime_buffer_copy(error, (const uint8_t *)message.data,
                                     message.size);
  }
  wasm_name_delete(&message);
  wasmtime_error_delete(wasmtime_error);
  return status;
}

int32_t cove_wasmtime_buffer_copy(cove_wasmtime_buffer_t *buffer,
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
  cove_wasmtime_buffer_delete(buffer);
  buffer->data = copy;
  buffer->size = size;
  return 0;
}

void cove_wasmtime_buffer_delete(cove_wasmtime_buffer_t *buffer) {
  if (buffer == NULL) {
    return;
  }
  free(buffer->data);
  buffer->data = NULL;
  buffer->size = 0;
}

const char *cove_wasmtime_runtime_version(void) { return WASMTIME_VERSION; }

cove_wasmtime_runtime_t *
cove_wasmtime_runtime_new(cove_wasmtime_execution_t execution,
                          cove_wasmtime_buffer_t *error) {
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  wasm_config_t *config = wasm_config_new();
  if (config == NULL) {
    (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Wasmtime configuration");
    return NULL;
  }
  bool interpreter = execution == COVE_WASMTIME_INTERPRETER;
#if defined(__APPLE__) && TARGET_OS_IPHONE
  // iOS, including Simulator, never requests executable pages for guest code.
  interpreter = true;
#endif
  if (interpreter) {
    wasmtime_error_t *target_error = wasmtime_config_target_set(
        config, sizeof(void *) == 8 ? "pulley64" : "pulley32");
    if (target_error != NULL) {
      (void)take_wasmtime_error(target_error, COVE_WASMTIME_COMPILE_ERROR, error);
      wasm_config_delete(config);
      return NULL;
    }
  }
  wasmtime_config_consume_fuel_set(config, true);
  wasmtime_config_epoch_interruption_set(config, true);
  wasmtime_config_wasm_component_model_set(config, true);
  wasm_engine_t *engine = wasm_engine_new_with_config(config);
  if (engine == NULL) {
    (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                    "could not create Wasmtime engine");
    return NULL;
  }
  cove_wasmtime_runtime_t *runtime =
      (cove_wasmtime_runtime_t *)calloc(1, sizeof(*runtime));
  if (runtime == NULL) {
    wasm_engine_delete(engine);
    (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Cove Wasmtime runtime");
    return NULL;
  }
  runtime->engine = engine;
  runtime->interpreter = interpreter;
  cove_mutex_init(&runtime->cache_lock);
  return runtime;
}

int32_t cove_wasmtime_runtime_is_interpreter(cove_wasmtime_runtime_t *runtime) {
  return runtime != NULL && runtime->interpreter;
}

void cove_wasmtime_runtime_delete(cove_wasmtime_runtime_t *runtime) {
  if (runtime == NULL) {
    return;
  }
  for (size_t index = 0; index < COVE_COMPONENT_CACHE_SIZE; index++) {
    cove_cached_component_t *entry = &runtime->cache[index];
    if (entry->component != NULL) {
      wasmtime_component_delete(entry->component);
    }
    free(entry->path);
    free(entry->bytes);
  }
  cove_mutex_destroy(&runtime->cache_lock);
  wasm_engine_delete(runtime->engine);
  free(runtime);
}

void cove_wasmtime_runtime_interrupt(cove_wasmtime_runtime_t *runtime) {
  if (runtime != NULL && runtime->engine != NULL) {
    wasmtime_engine_increment_epoch(runtime->engine);
  }
}

static cove_wasmtime_status_t
read_component(const char *path, uint8_t **bytes_out, size_t *size_out,
               cove_wasmtime_buffer_t *error) {
  if (path == NULL || bytes_out == NULL || size_out == NULL) {
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                     "invalid component path");
  }
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    return set_error(error, COVE_WASMTIME_IO_ERROR,
                     "could not open component.wasm");
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return set_error(error, COVE_WASMTIME_IO_ERROR,
                     "could not measure component.wasm");
  }
  long measured = ftell(file);
  if (measured < 0 || (uint64_t)measured > COVE_MAX_COMPONENT_BYTES) {
    fclose(file);
    return set_error(error, COVE_WASMTIME_IO_ERROR,
                     "component.wasm exceeds 128 MiB");
  }
  if (fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return set_error(error, COVE_WASMTIME_IO_ERROR,
                     "could not rewind component.wasm");
  }
  size_t size = (size_t)measured;
  uint8_t *bytes = size == 0 ? NULL : (uint8_t *)malloc(size);
  if (bytes == NULL && size > 0) {
    fclose(file);
    return set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                     "could not allocate component buffer");
  }
  if (size > 0 && fread(bytes, 1, size, file) != size) {
    free(bytes);
    fclose(file);
    return set_error(error, COVE_WASMTIME_IO_ERROR,
                     "could not read complete component.wasm");
  }
  fclose(file);
  *bytes_out = bytes;
  *size_out = size;
  return COVE_WASMTIME_OK;
}

static cove_wasmtime_status_t
compile_component(cove_wasmtime_runtime_t *runtime, const char *path,
                  wasmtime_component_t **component_out,
                  cove_wasmtime_buffer_t *error) {
  uint8_t *bytes = NULL;
  size_t size = 0;
  cove_wasmtime_status_t status =
      read_component(path, &bytes, &size, error);
  if (status != COVE_WASMTIME_OK) {
    return status;
  }
  cove_mutex_lock(&runtime->cache_lock);
  for (size_t index = 0; index < COVE_COMPONENT_CACHE_SIZE; index++) {
    cove_cached_component_t *entry = &runtime->cache[index];
    if (entry->component != NULL && entry->size == size &&
        strcmp(entry->path, path) == 0 &&
        (size == 0 || memcmp(entry->bytes, bytes, size) == 0)) {
      entry->last_use = ++runtime->cache_clock;
      *component_out = wasmtime_component_clone(entry->component);
      cove_mutex_unlock(&runtime->cache_lock);
      free(bytes);
      return COVE_WASMTIME_OK;
    }
  }
  cove_mutex_unlock(&runtime->cache_lock);

  wasmtime_component_t *component = NULL;
  wasmtime_error_t *wasmtime_error = wasmtime_component_new(
      runtime->engine, bytes, size, &component);
  if (wasmtime_error != NULL) {
    free(bytes);
    return take_wasmtime_error(wasmtime_error, COVE_WASMTIME_COMPILE_ERROR,
                               error);
  }
  char *path_copy = (char *)malloc(strlen(path) + 1);
  if (path_copy == NULL) {
    free(bytes);
    *component_out = component;
    return COVE_WASMTIME_OK;
  }
  strcpy(path_copy, path);
  cove_mutex_lock(&runtime->cache_lock);
  cove_cached_component_t *slot = &runtime->cache[0];
  for (size_t index = 0; index < COVE_COMPONENT_CACHE_SIZE; index++) {
    cove_cached_component_t *entry = &runtime->cache[index];
    if (entry->component == NULL) {
      slot = entry;
      break;
    }
    if (entry->last_use < slot->last_use) {
      slot = entry;
    }
  }
  if (slot->component != NULL) {
    wasmtime_component_delete(slot->component);
  }
  free(slot->path);
  free(slot->bytes);
  slot->path = path_copy;
  slot->bytes = bytes;
  slot->size = size;
  slot->component = component;
  slot->last_use = ++runtime->cache_clock;
  *component_out = wasmtime_component_clone(component);
  cove_mutex_unlock(&runtime->cache_lock);
  return COVE_WASMTIME_OK;
}

static bool bytes_equal(const char *bytes, size_t size, const char *expected) {
  size_t expected_size = strlen(expected);
  return size == expected_size && memcmp(bytes, expected, size) == 0;
}

static bool validate_string_function(
    const wasmtime_component_func_type_t *function,
    const char *const *parameter_names, size_t parameter_count,
    cove_wasmtime_buffer_t *error, const char *display_name) {
  if (wasmtime_component_func_type_async(function)) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "%s must be synchronous", display_name);
    return false;
  }
  if (wasmtime_component_func_type_param_count(function) != parameter_count) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "%s has the wrong parameter count", display_name);
    return false;
  }
  for (size_t index = 0; index < parameter_count; index++) {
    const char *name = NULL;
    size_t name_size = 0;
    wasmtime_component_valtype_t type;
    if (!wasmtime_component_func_type_param_nth(function, index, &name,
                                                &name_size, &type)) {
      (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                      "%s parameter reflection failed", display_name);
      return false;
    }
    bool valid = type.kind == WASMTIME_COMPONENT_VALTYPE_STRING &&
                 bytes_equal(name, name_size, parameter_names[index]);
    wasmtime_component_valtype_delete(&type);
    if (!valid) {
      (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                      "%s parameters must exactly match the Cove string ABI",
                      display_name);
      return false;
    }
  }
  wasmtime_component_valtype_t result;
  if (!wasmtime_component_func_type_result(function, &result)) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "%s must return string", display_name);
    return false;
  }
  bool valid_result = result.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
  wasmtime_component_valtype_delete(&result);
  if (!valid_result) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "%s must return string", display_name);
    return false;
  }
  return true;
}

// Wasmtime 49 reflects imports/exports through an owned extern descriptor.
// Extract an owned item before deleting that descriptor; callers continue to
// own and delete the item while keeping its original component type alive.
static bool component_type_import_item(
    const wasmtime_component_type_t *type, const wasm_engine_t *engine,
    const char *name, size_t name_size, wasmtime_component_item_t *item) {
  wasmtime_component_extern_t *external = NULL;
  if (!wasmtime_component_type_import_get(type, engine, name, name_size,
                                          &external)) {
    return false;
  }
  wasmtime_component_extern_type(external, item);
  wasmtime_component_extern_delete(external);
  return true;
}

static bool component_type_export_item(
    const wasmtime_component_type_t *type, const wasm_engine_t *engine,
    const char *name, size_t name_size, wasmtime_component_item_t *item) {
  wasmtime_component_extern_t *external = NULL;
  if (!wasmtime_component_type_export_get(type, engine, name, name_size,
                                          &external)) {
    return false;
  }
  wasmtime_component_extern_type(external, item);
  wasmtime_component_extern_delete(external);
  return true;
}

static bool instance_type_export_item(
    const wasmtime_component_instance_type_t *type,
    const wasm_engine_t *engine, const char *name, size_t name_size,
    wasmtime_component_item_t *item) {
  wasmtime_component_extern_t *external = NULL;
  if (!wasmtime_component_instance_type_export_get(type, engine, name,
                                                   name_size, &external)) {
    return false;
  }
  wasmtime_component_extern_type(external, item);
  wasmtime_component_extern_delete(external);
  return true;
}

static bool instance_type_export_item_at(
    const wasmtime_component_instance_type_t *type,
    const wasm_engine_t *engine, size_t index, const char **name,
    size_t *name_size, wasmtime_component_item_t *item) {
  wasmtime_component_extern_t *external = NULL;
  if (!wasmtime_component_instance_type_export_nth(type, engine, index, name,
                                                   name_size, &external)) {
    return false;
  }
  wasmtime_component_extern_type(external, item);
  wasmtime_component_extern_delete(external);
  return true;
}

static bool validate_query_import(const wasmtime_component_item_t *item,
                                  cove_wasmtime_runtime_t *runtime,
                                  const char *import_name,
                                  cove_wasmtime_buffer_t *error) {
  if (item->kind != WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "import %s must be a component interface", import_name);
    return false;
  }
  const wasmtime_component_instance_type_t *instance =
      item->of.component_instance;
  if (wasmtime_component_instance_type_export_count(instance, runtime->engine) !=
      1) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "import %s must expose only query", import_name);
    return false;
  }
  wasmtime_component_item_t query;
  if (!instance_type_export_item(
          instance, runtime->engine, "query", strlen("query"), &query)) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
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
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "import %s query must be a function", import_name);
  }
  wasmtime_component_item_delete(&query);
  return valid;
}

typedef struct cove_signature_builder {
  char *data;
  size_t size;
  size_t capacity;
} cove_signature_builder_t;

static void signature_builder_delete(cove_signature_builder_t *builder) {
  if (builder == NULL) {
    return;
  }
  free(builder->data);
  builder->data = NULL;
  builder->size = 0;
  builder->capacity = 0;
}

static bool signature_append(cove_signature_builder_t *builder,
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

static bool signature_literal(cove_signature_builder_t *builder,
                              const char *literal) {
  return signature_append(builder, literal, strlen(literal));
}

static bool append_type_signature(const wasmtime_component_valtype_t *type,
                                  cove_signature_builder_t *builder,
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
    const char *expected_signature, cove_wasmtime_buffer_t *error) {
  if (wasmtime_component_func_type_async(function) ||
      wasmtime_component_func_type_param_count(function) != 1) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
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
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s parameter must be named input", name);
    return false;
  }
  cove_signature_builder_t signature = {0};
  bool valid = append_type_signature(&input_type, &signature, 0) &&
               expected_signature != NULL && signature.data != NULL &&
               strcmp(signature.data, expected_signature) == 0;
  wasmtime_component_valtype_delete(&input_type);
  signature_builder_delete(&signature);
  if (!valid) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s input type does not match capabilities.wit",
                    name);
    return false;
  }
  wasmtime_component_valtype_t result = {0};
  if (!wasmtime_component_func_type_result(function, &result)) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s must return string", name);
    return false;
  }
  valid = result.kind == WASMTIME_COMPONENT_VALTYPE_STRING;
  wasmtime_component_valtype_delete(&result);
  if (!valid) {
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "capability %s must return string", name);
  }
  return valid;
}

static cove_wasmtime_status_t validate_contract(
    cove_wasmtime_runtime_t *runtime, const wasmtime_component_t *component,
    const char *capabilities_interface_name,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
    cove_wasmtime_buffer_t *error) {
  wasmtime_component_type_t *type = wasmtime_component_type(component);
  if (type == NULL) {
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "could not reflect component type");
  }
  if (wasmtime_component_type_import_count(type, runtime->engine) !=
      expected_import_count) {
    wasmtime_component_type_delete(type);
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "component imports do not match capabilities.wit");
  }
  for (size_t index = 0; index < expected_import_count; index++) {
    const char *name = expected_imports[index];
    if (name == NULL) {
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                       "expected import name is null");
    }
    wasmtime_component_item_t item;
    if (!component_type_import_item(type, runtime->engine, name,
                                            strlen(name), &item)) {
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                       "component is missing declared import %s", name);
    }
    bool valid = validate_query_import(&item, runtime, name, error);
    wasmtime_component_item_delete(&item);
    if (!valid) {
      wasmtime_component_type_delete(type);
      return COVE_WASMTIME_CONTRACT_MISMATCH;
    }
  }
  if (wasmtime_component_type_export_count(type, runtime->engine) != 1) {
    wasmtime_component_type_delete(type);
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "component must export exactly the capabilities interface");
  }
  wasmtime_component_item_t capabilities = {0};
  bool has_capabilities = component_type_export_item(
      type, runtime->engine, capabilities_interface_name,
      strlen(capabilities_interface_name),
      &capabilities);
  if (!has_capabilities ||
      capabilities.kind != WASMTIME_COMPONENT_ITEM_COMPONENT_INSTANCE) {
    if (has_capabilities) {
      wasmtime_component_item_delete(&capabilities);
    }
    wasmtime_component_type_delete(type);
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "component is missing capabilities interface export");
  }
  const wasmtime_component_instance_type_t *instance =
      capabilities.of.component_instance;
  size_t instance_export_count = wasmtime_component_instance_type_export_count(
      instance, runtime->engine);
  if (instance_export_count < expected_capability_count * 2 ||
      instance_export_count > 256) {
    wasmtime_component_item_delete(&capabilities);
    wasmtime_component_type_delete(type);
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "Component capability count does not match capabilities.wit");
  }
  size_t reflected_function_count = 0;
  for (size_t export_index = 0; export_index < instance_export_count;
       export_index++) {
    const char *export_name = NULL;
    size_t export_name_size = 0;
    wasmtime_component_item_t item = {0};
    if (!instance_type_export_item_at(
            instance, runtime->engine, export_index, &export_name,
            &export_name_size, &item)) {
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                       "could not reflect capabilities interface export");
    }
    if (item.kind == WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC) {
      reflected_function_count++;
      bool declared = false;
      for (size_t expected_index = 0;
           expected_index < expected_capability_count; expected_index++) {
        const char *expected_name = expected_capabilities[expected_index];
        if (expected_name != NULL &&
            bytes_equal(export_name, export_name_size, expected_name)) {
          declared = true;
          break;
        }
      }
      if (!declared) {
        wasmtime_component_item_delete(&item);
        wasmtime_component_item_delete(&capabilities);
        wasmtime_component_type_delete(type);
        return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                         "Component exposes a capability absent from capabilities.wit");
      }
    } else if (item.kind != WASMTIME_COMPONENT_ITEM_TYPE) {
      wasmtime_component_item_delete(&item);
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                       "capabilities interface contains a forbidden export");
    }
    wasmtime_component_item_delete(&item);
  }
  if (reflected_function_count != expected_capability_count) {
    wasmtime_component_item_delete(&capabilities);
    wasmtime_component_type_delete(type);
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "Component capability count does not match capabilities.wit");
  }
  for (size_t index = 0; index < expected_capability_count; index++) {
    const char *name = expected_capabilities[index];
    const char *signature = expected_type_signatures[index];
    if (name == NULL || signature == NULL) {
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                       "expected capability metadata is null");
    }
    wasmtime_component_item_t function = {0};
    char input_type_name[80];
    int input_type_name_size = snprintf(input_type_name,
                                        sizeof(input_type_name), "%s-input",
                                        name);
    wasmtime_component_item_t exported_input_type = {0};
    bool has_exported_input_type = input_type_name_size > 0 &&
        (size_t)input_type_name_size < sizeof(input_type_name) &&
        instance_type_export_item(
            instance, runtime->engine, input_type_name,
            (size_t)input_type_name_size, &exported_input_type);
    if (!has_exported_input_type ||
        exported_input_type.kind != WASMTIME_COMPONENT_ITEM_TYPE) {
      if (has_exported_input_type) {
        wasmtime_component_item_delete(&exported_input_type);
      }
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                       "component is missing exported input type for %s", name);
    }
    wasmtime_component_item_delete(&exported_input_type);
    bool has_function = instance_type_export_item(
        instance, runtime->engine, name, strlen(name), &function);
    if (!has_function ||
        function.kind != WASMTIME_COMPONENT_ITEM_COMPONENT_FUNC ||
        !validate_capability_function(function.of.component_func, name,
                                      signature, error)) {
      if (has_function) {
        wasmtime_component_item_delete(&function);
      }
      if (error == NULL || error->size == 0) {
        (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                        "component is missing typed capability %s", name);
      }
      wasmtime_component_item_delete(&capabilities);
      wasmtime_component_type_delete(type);
      return COVE_WASMTIME_CONTRACT_MISMATCH;
    }
    wasmtime_component_item_delete(&function);
  }
  wasmtime_component_item_delete(&capabilities);
  wasmtime_component_type_delete(type);
  return COVE_WASMTIME_OK;
}

static wasmtime_store_t *
make_store(cove_wasmtime_runtime_t *runtime,
           const cove_wasmtime_limits_t *limits,
           cove_wasmtime_buffer_t *error) {
  wasmtime_store_t *store = wasmtime_store_new(runtime->engine, NULL, NULL);
  if (store == NULL) {
    (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
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
                              COVE_WASMTIME_INVOCATION_ERROR, error);
    wasmtime_store_delete(store);
    return NULL;
  }
  // One engine epoch advancement interrupts this invocation. Swift schedules
  // the wall-clock deadline and calls cove_wasmtime_runtime_interrupt.
  wasmtime_context_set_epoch_deadline(context, 1);
  return store;
}

static void delete_host_binding(void *opaque) {
  cove_host_binding_t *binding = (cove_host_binding_t *)opaque;
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
  cove_host_binding_t *binding = (cove_host_binding_t *)opaque;
  if (binding == NULL || binding->callback == NULL) {
    return wasmtime_error_new("Cove query context is unavailable");
  }
  if (argument_count != 1 || result_count != 1 ||
      args[0].kind != WASMTIME_COMPONENT_STRING) {
    return wasmtime_error_new("Cove query called with an invalid ABI");
  }
  if (args[0].of.string.size > binding->maximum_query_request_bytes) {
    return wasmtime_error_new("Cove query request exceeds its byte limit");
  }
  cove_wasmtime_buffer_t response = {0};
  cove_wasmtime_buffer_t callback_error = {0};
  int32_t callback_status = binding->callback(
      binding->environment, binding->interface_name,
      binding->interface_name_size, (const uint8_t *)args[0].of.string.data,
      args[0].of.string.size, &response, &callback_error);
  if (callback_status != 0) {
    char *message = terminated_copy(callback_error.data, callback_error.size,
                                    "Cove query was rejected");
    cove_wasmtime_buffer_delete(&response);
    cove_wasmtime_buffer_delete(&callback_error);
    if (message == NULL) {
      return wasmtime_error_new("Cove query failed without diagnostics");
    }
    wasmtime_error_t *error = wasmtime_error_new(message);
    free(message);
    return error;
  }
  cove_wasmtime_buffer_delete(&callback_error);
  if (response.size > binding->maximum_output_bytes) {
    cove_wasmtime_buffer_delete(&response);
    return wasmtime_error_new("Cove query response exceeds its byte limit");
  }
  results[0].kind = WASMTIME_COMPONENT_STRING;
  wasm_name_new(&results[0].of.string, response.size,
                (const char *)response.data);
  cove_wasmtime_buffer_delete(&response);
  return NULL;
}

static wasmtime_component_linker_t *build_linker(
    cove_wasmtime_runtime_t *runtime, const char *const *expected_imports,
    size_t expected_import_count, cove_wasmtime_query_callback_t callback,
    void *environment, const cove_wasmtime_limits_t *limits,
    cove_wasmtime_buffer_t *error) {
  wasmtime_component_linker_t *linker =
      wasmtime_component_linker_new(runtime->engine);
  if (linker == NULL) {
    (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                    "could not allocate Component linker");
    return NULL;
  }
  wasmtime_component_linker_instance_t *root =
      wasmtime_component_linker_root(linker);
  if (root == NULL) {
    wasmtime_component_linker_delete(linker);
    (void)set_error(error, COVE_WASMTIME_LINK_ERROR,
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
      (void)take_wasmtime_error(wasmtime_error, COVE_WASMTIME_LINK_ERROR,
                                error);
      return NULL;
    }
    cove_host_binding_t *binding =
        (cove_host_binding_t *)calloc(1, sizeof(*binding));
    if (binding == NULL) {
      wasmtime_component_linker_instance_delete(child);
      wasmtime_component_linker_instance_delete(root);
      wasmtime_component_linker_delete(linker);
      (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate Cove host binding");
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
      (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                      "could not copy Cove import name");
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
      (void)take_wasmtime_error(wasmtime_error, COVE_WASMTIME_LINK_ERROR,
                                error);
      return NULL;
    }
    wasmtime_component_linker_instance_delete(child);
  }
  wasmtime_component_linker_instance_delete(root);
  return linker;
}

static cove_wasmtime_status_t instantiate_component(
    cove_wasmtime_runtime_t *runtime, const wasmtime_component_t *component,
    const char *const *expected_imports, size_t expected_import_count,
    cove_wasmtime_query_callback_t callback, void *environment,
    const cove_wasmtime_limits_t *limits, wasmtime_store_t **store_out,
    wasmtime_component_instance_t *instance_out,
    cove_wasmtime_buffer_t *error) {
  wasmtime_store_t *store = make_store(runtime, limits, error);
  if (store == NULL) {
    return COVE_WASMTIME_INVOCATION_ERROR;
  }
  wasmtime_component_linker_t *linker = build_linker(
      runtime, expected_imports, expected_import_count, callback, environment,
      limits, error);
  if (linker == NULL) {
    wasmtime_store_delete(store);
    return COVE_WASMTIME_LINK_ERROR;
  }
  wasmtime_error_t *wasmtime_error = wasmtime_component_linker_instantiate(
      linker, wasmtime_store_context(store), component, instance_out);
  wasmtime_component_linker_delete(linker);
  if (wasmtime_error != NULL) {
    wasmtime_store_delete(store);
    return take_wasmtime_error(wasmtime_error, COVE_WASMTIME_LINK_ERROR,
                               error);
  }
  *store_out = store;
  return COVE_WASMTIME_OK;
}

static bool valid_limits(const cove_wasmtime_limits_t *limits) {
  return limits != NULL && limits->maximum_memory_bytes > 0 &&
         limits->maximum_memory_bytes <= 256ULL * 1024ULL * 1024ULL &&
         limits->fuel_per_invocation > 0 &&
         limits->maximum_output_bytes > 0 &&
         limits->maximum_output_bytes <= 256ULL * 1024ULL * 1024ULL &&
         limits->maximum_query_request_bytes > 0 &&
         limits->maximum_query_request_bytes <= 16ULL * 1024ULL &&
         limits->maximum_instances > 0 && limits->maximum_instances <= 64 &&
         limits->maximum_tables > 0 && limits->maximum_tables <= 16 &&
         limits->maximum_memories > 0 && limits->maximum_memories <= 16 &&
         limits->maximum_table_elements > 0 &&
         limits->maximum_table_elements <= 100000;
}

typedef struct cove_typed_cursor {
  const uint8_t *data;
  size_t size;
  size_t offset;
} cove_typed_cursor_t;

static bool cursor_read(cove_typed_cursor_t *cursor, void *output,
                        size_t size) {
  if (cursor == NULL || output == NULL || size > cursor->size ||
      cursor->offset > cursor->size - size) {
    return false;
  }
  memcpy(output, cursor->data + cursor->offset, size);
  cursor->offset += size;
  return true;
}

static bool cursor_u8(cove_typed_cursor_t *cursor, uint8_t *output) {
  return cursor_read(cursor, output, 1);
}

static bool cursor_u16(cove_typed_cursor_t *cursor, uint16_t *output) {
  uint8_t bytes[2];
  if (!cursor_read(cursor, bytes, sizeof(bytes))) {
    return false;
  }
  *output = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
  return true;
}

static bool cursor_u32(cove_typed_cursor_t *cursor, uint32_t *output) {
  uint8_t bytes[4];
  if (!cursor_read(cursor, bytes, sizeof(bytes))) {
    return false;
  }
  *output = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
            ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
  return true;
}

static bool cursor_u64(cove_typed_cursor_t *cursor, uint64_t *output) {
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

static bool decode_typed_value(cove_typed_cursor_t *cursor,
                               const wasmtime_component_valtype_t *type,
                               wasmtime_component_val_t *output,
                               size_t depth,
                               cove_wasmtime_buffer_t *error) {
  if (cursor == NULL || type == NULL || output == NULL || depth > 12) {
    (void)set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
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
      (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                      "could not allocate typed option value");
      return false;
    }
    return true;
  }
  case WASMTIME_COMPONENT_VALTYPE_LIST: {
    uint32_t count = 0;
    if (!cursor_u32(cursor, &count) || count > (1u << 24)) {
      break;
    }
    output->kind = WASMTIME_COMPONENT_LIST;
    wasmtime_component_vallist_new_uninit(&output->of.list, count);
    if (count > 0 && output->of.list.data == NULL) {
      (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
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
      (void)set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
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
    (void)set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                    "Component capability uses an unsupported typed value");
    return false;
  }
  (void)set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                  "typed capability input is truncated or malformed");
  return false;
}

cove_wasmtime_status_t cove_wasmtime_validate_component(
    cove_wasmtime_runtime_t *runtime, const char *component_path,
    const char *capabilities_interface_name,
    const char *const *expected_imports, size_t expected_import_count,
    const char *const *expected_capabilities,
    const char *const *expected_type_signatures,
    size_t expected_capability_count,
    const cove_wasmtime_limits_t *limits, cove_wasmtime_buffer_t *error) {
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (runtime == NULL || component_path == NULL ||
      capabilities_interface_name == NULL ||
      (expected_import_count > 0 && expected_imports == NULL) ||
      (expected_capability_count > 0 &&
       (expected_capabilities == NULL || expected_type_signatures == NULL)) ||
      expected_import_count > 16 || expected_capability_count > 64 ||
      !valid_limits(limits)) {
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                     "invalid Component validation arguments");
  }
  wasmtime_component_t *component = NULL;
  cove_wasmtime_status_t status =
      compile_component(runtime, component_path, &component, error);
  if (status != COVE_WASMTIME_OK) {
    return status;
  }
  status = validate_contract(runtime, component, capabilities_interface_name,
                             expected_imports,
                             expected_import_count, expected_capabilities,
                             expected_type_signatures,
                             expected_capability_count, error);
  if (status == COVE_WASMTIME_OK) {
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
    cove_wasmtime_buffer_t *error) {
  if (output != NULL) {
    output->data = NULL;
    output->size = 0;
  }
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (runtime == NULL || component_path == NULL ||
      capabilities_interface_name == NULL || capability_name == NULL ||
      output == NULL || !valid_limits(limits) ||
      typed_input == NULL || typed_input_size < 4 ||
      typed_input_size > limits->maximum_output_bytes ||
      (expected_import_count > 0 && expected_imports == NULL) ||
      (expected_capability_count > 0 &&
       (expected_capabilities == NULL || expected_type_signatures == NULL)) ||
      expected_import_count > 16 || expected_capability_count > 64) {
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
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
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                     "capability is absent from capabilities.wit");
  }
  const uint8_t magic[] = {0x47, 0x54, 0x56, 0x31};
  if (memcmp(typed_input, magic, sizeof(magic)) != 0) {
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                     "typed capability input has an unsupported version");
  }
  wasmtime_component_t *component = NULL;
  cove_wasmtime_status_t status =
      compile_component(runtime, component_path, &component, error);
  if (status != COVE_WASMTIME_OK) {
    return status;
  }
  status = validate_contract(runtime, component, capabilities_interface_name,
                             expected_imports,
                             expected_import_count, expected_capabilities,
                             expected_type_signatures,
                             expected_capability_count, error);
  if (status != COVE_WASMTIME_OK) {
    wasmtime_component_delete(component);
    return status;
  }
  wasmtime_store_t *store = NULL;
  wasmtime_component_instance_t instance = {0};
  status = instantiate_component(
      runtime, component, expected_imports, expected_import_count,
      query_callback, query_environment, limits, &store, &instance, error);
  if (status != COVE_WASMTIME_OK) {
    wasmtime_component_delete(component);
    return status;
  }
  wasmtime_context_t *context = wasmtime_store_context(store);
  wasmtime_component_export_index_t *capabilities_index =
      wasmtime_component_get_export_index(
          component, NULL, capabilities_interface_name,
          strlen(capabilities_interface_name));
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
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
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
    return set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                     "could not reflect typed capability input");
  }
  wasmtime_component_func_type_delete(function_type);
  cove_typed_cursor_t cursor = {
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
      return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                       "typed capability input has trailing or invalid bytes");
    }
    return COVE_WASMTIME_INVALID_ARGUMENT;
  }
  wasmtime_component_val_t result = {0};
  wasmtime_error_t *wasmtime_error = wasmtime_component_func_call(
      &function, context, &component_argument, 1, &result, 1);
  wasmtime_component_val_delete(&component_argument);
  if (wasmtime_error != NULL) {
    status = take_wasmtime_error(wasmtime_error,
                                 COVE_WASMTIME_INVOCATION_ERROR, error);
  } else if (result.kind != WASMTIME_COMPONENT_STRING) {
    status = set_error(error, COVE_WASMTIME_CONTRACT_MISMATCH,
                       "Component export returned a non-string value");
  } else if (result.of.string.size > limits->maximum_output_bytes) {
    status = set_error(error, COVE_WASMTIME_OUTPUT_TOO_LARGE,
                       "Component output exceeds its limit");
  } else if (cove_wasmtime_buffer_copy(
                 output, (const uint8_t *)result.of.string.data,
                 result.of.string.size) != 0) {
    status = set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                       "could not copy Component output");
  }
  if (wasmtime_error == NULL) {
    wasmtime_component_val_delete(&result);
  }
  wasmtime_store_delete(store);
  wasmtime_component_delete(component);
  return status;
}

cove_wasmtime_status_t cove_wasmtime_component_wat2wasm(
    const uint8_t *wat, size_t wat_size, cove_wasmtime_buffer_t *output,
    cove_wasmtime_buffer_t *error) {
  if (output != NULL) {
    output->data = NULL;
    output->size = 0;
  }
  if (error != NULL) {
    error->data = NULL;
    error->size = 0;
  }
  if (wat == NULL || wat_size == 0 || output == NULL) {
    return set_error(error, COVE_WASMTIME_INVALID_ARGUMENT,
                     "component WAT is empty");
  }
  wasm_byte_vec_t binary;
  wasmtime_error_t *wasmtime_error =
      wasmtime_wat2wasm((const char *)wat, wat_size, &binary);
  if (wasmtime_error != NULL) {
    return take_wasmtime_error(wasmtime_error, COVE_WASMTIME_COMPILE_ERROR,
                               error);
  }
  cove_wasmtime_status_t status = COVE_WASMTIME_OK;
  if (cove_wasmtime_buffer_copy(output, (const uint8_t *)binary.data,
                                 binary.size) != 0) {
    status = set_error(error, COVE_WASMTIME_OUT_OF_MEMORY,
                       "could not copy compiled component WAT");
  }
  wasm_byte_vec_delete(&binary);
  return status;
}
