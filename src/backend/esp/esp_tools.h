/* ESP32-side tool registry. Each tool is a C function that takes a
 * cJSON input and returns a malloc'd output string (the user-visible
 * tool_result content, JSON-stringifiable text). The agent loop in
 * esp_agent.c iterates over psi_esp_tool_table during the request to
 * advertise tools and dispatches by name when a tool_use content
 * block resolves. */

#ifndef PSI_ESP_TOOLS_H
#define PSI_ESP_TOOLS_H

#include "cJSON.h"

/* Firmware feature flags. CMake (components/psi/CMakeLists.txt) sets
 * these unconditionally for the firmware build; the fallbacks below
 * keep the headers self-contained so editor tooling doesn't trip on
 * #if of an undefined macro. */
#ifndef PSI_INCLUDE_SPA
#define PSI_INCLUDE_SPA 1
#endif
#ifndef PSI_GPIO_INTROSPECTION
#define PSI_GPIO_INTROSPECTION 1
#endif

struct psi_esp_tool {
    const char *name;
    const char *description;
    /* JSON Schema literal as a C string. Anthropic accepts the same
     * shape as OpenAI function tools: {"type":"object","properties":...}. */
    const char *input_schema_json;
    /* Handler: input is the JSON object the model produced. Return a
     * heap-allocated string for the tool_result content (caller frees).
     * On error, return NULL and set *err to a heap string. */
    char *(*handler)(const cJSON *input, char **err);
};

/* Null-terminated table of all built-in ESP tools. */
extern const struct psi_esp_tool psi_esp_tool_table[];

/* Convenience: find by name; returns NULL if absent. */
const struct psi_esp_tool *psi_esp_tool_find(const char *name);

#if PSI_GPIO_INTROSPECTION
/* Snapshot of every GPIO's configured mode + last commanded level.
 * Caller frees the returned heap string. Compiled out when
 * PSI_GPIO_INTROSPECTION=0 — real-hardware deploys measure pins
 * directly. */
char *psi_esp_gpio_snapshot_json(void);
#endif

#endif
