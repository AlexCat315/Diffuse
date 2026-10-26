// A portable executable used by the Android/iOS/native runtime gates.
#include "CWasmtimeBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(cove_wasmtime_status_t status, cove_wasmtime_buffer_t *error) {
  if (status != COVE_WASMTIME_OK) {
    fprintf(stderr, "bridge %d: %.*s\n", status, (int)error->size, error->data);
    exit(1);
  }
  cove_wasmtime_buffer_delete(error);
}
static int compile(const char *input, const char *output) {
  FILE *file = fopen(input, "rb"); if (!file) return 1;
  fseek(file, 0, SEEK_END); long size = ftell(file); rewind(file);
  if (size < 0 || size > 1024 * 1024) return 1;
  uint8_t *bytes = malloc((size_t)size);
  if (fread(bytes, 1, (size_t)size, file) != (size_t)size) return 1;
  fclose(file);
  cove_wasmtime_buffer_t result = {0}, error = {0};
  check(cove_wasmtime_component_wat2wasm(bytes, (size_t)size, &result, &error), &error);
  free(bytes); file = fopen(output, "wb"); if (!file) return 1;
  int ok = fwrite(result.data, 1, result.size, file) == result.size;
  fclose(file); cove_wasmtime_buffer_delete(&result); return ok ? 0 : 1;
}
static int32_t query(void *environment, const uint8_t *name, size_t name_size,
                     const uint8_t *request, size_t request_size,
                     cove_wasmtime_buffer_t *response, cove_wasmtime_buffer_t *error) {
  (void)environment; (void)error;
  const char *expected = "cove:scene/query";
  const char *expected_request = "{\"operation\":\"snapshot\"}";
  if (name_size != strlen(expected) || memcmp(name, expected, name_size) ||
      request_size != strlen(expected_request) || memcmp(request, expected_request, request_size)) return 1;
  const char *value = "{\"entities\":[],\"revision\":42}";
  return cove_wasmtime_buffer_copy(response, (const uint8_t *)value, strlen(value));
}
int main(int argc, char **argv) {
  if (argc == 4 && strcmp(argv[1], "--compile") == 0) return compile(argv[2], argv[3]);
  if (argc != 5) { fprintf(stderr, "Usage: probe <reader.wasm> <query.wasm> <infinite.wasm> native|pulley\n"); return 1; }
  cove_wasmtime_buffer_t error = {0};
  cove_wasmtime_runtime_t *runtime = cove_wasmtime_runtime_new(
    strcmp(argv[4], "pulley") == 0 ? COVE_WASMTIME_INTERPRETER : COVE_WASMTIME_AUTOMATIC, &error);
  if (!runtime) { fprintf(stderr, "%.*s\n", (int)error.size, error.data); return 1; }
  cove_wasmtime_limits_t limits = {64*1024*1024, 20000000, 10000, 64, 16, 16, 1048576, 16384};
  const char *signature[] = {"record{enabled:bool}"};
  const char *names[] = {"inspect"};
  const char *imports[] = {"cove:scene/query"};
  uint8_t input[] = {'G', 'T', 'V', '1', 1};
  for (int i = 1; i <= 3; i++) {
    const char *loop_names[] = {"loop"};
    const char **capabilities = i == 3 ? loop_names : names;
    size_t import_count = i == 2 ? 1 : 0;
    check(cove_wasmtime_validate_component(runtime, argv[i], "safe:reader/capabilities",
      imports, import_count, capabilities, signature, 1, &limits, &error), &error);
    cove_wasmtime_buffer_t output = {0};
    cove_wasmtime_status_t status = cove_wasmtime_invoke_capability(runtime, argv[i],
      "safe:reader/capabilities", capabilities[0], input, sizeof(input), imports, import_count,
      capabilities, signature, 1, query, NULL, &limits, &output, &error);
    if (i == 3) {
      if (status == COVE_WASMTIME_OK) { fprintf(stderr, "Fuel limit did not trap\n"); return 1; }
      printf("fuel trap: %.*s\n", (int)error.size, error.data);
      cove_wasmtime_buffer_delete(&error);
    } else {
      check(status, &error);
      const char *expected = i == 1 ? "true" : "{\"entities\":[],\"revision\":42}";
      if (output.size != strlen(expected) || memcmp(output.data, expected, output.size)) return 1;
      printf("component %d: %.*s\n", i, (int)output.size, output.data);
    }
    cove_wasmtime_buffer_delete(&output);
  }
  printf("PASS Wasmtime %s execution=%s\n", cove_wasmtime_runtime_version(),
    cove_wasmtime_runtime_is_interpreter(runtime) ? "pulley" : "native");
  cove_wasmtime_runtime_delete(runtime); return 0;
}
