/* ESP32-side tool registry. Each tool is a C function that takes a
 * cJSON input and returns a malloc'd output string (the user-visible
 * tool_result content, JSON-stringifiable text). The agent loop in
 * esp_agent.c iterates over psi_esp_tool_table during the request to
 * advertise tools and dispatches by name when a tool_use content
 * block resolves. */

#ifndef PSI_ESP_TOOLS_H
#define PSI_ESP_TOOLS_H

#include "cJSON.h"

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

#endif
