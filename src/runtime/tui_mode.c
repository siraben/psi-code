#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <cjson/cJSON.h>
#include <ncurses.h>
#include "psi/agent.h"
#include "psi/common.h"
#include "psi/message.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

enum psi_tui_entry_kind {
    PSI_TUI_ENTRY_USER = 0,
    PSI_TUI_ENTRY_ASSISTANT = 1,
    PSI_TUI_ENTRY_TOOL_CALL = 2,
    PSI_TUI_ENTRY_TOOL_RESULT = 3,
    PSI_TUI_ENTRY_INFO = 4,
    PSI_TUI_ENTRY_ERROR = 5,
    PSI_TUI_ENTRY_COMPACTION = 6,
    PSI_TUI_ENTRY_THINKING = 7
};

struct psi_tui_entry {
    enum psi_tui_entry_kind kind;
    char *title;
    char *text;
    int is_error;
    /* Tool-call id tag. Set on TOOL_CALL entries and the matching
     * TOOL_RESULT placeholder created alongside them; used by
     * psi_tui_observer_tool_progress / _tool_result to route
     * streamed chunks and final output to the right entry when
     * multiple tools run concurrently (sched.run_all). NULL for
     * every other entry kind. Owned — freed by psi_tui_free_entry. */
    char *tool_call_id;
};

struct psi_tui_render_line {
    char *text;
    int color_pair;
    int attrs;
    /* Markdown handling for assistant-entry lines. Both flags are 0
     * for every other entry kind and for pre-markdown assistant text
     * alike (is_assistant=0 means "draw with mvaddnstr, no parsing").
     * in_code_fence=1 forces the entire wrapped line to render dim
     * without inline parsing even when source text happens to look
     * like markdown inside a fence. */
    int is_assistant;
    int in_code_fence;
};

struct psi_tui_state {
    struct psi_agent_runtime runtime;
    const struct psi_cli_options *options;
    struct psi_tui_entry *entries;
    size_t entry_count;
    size_t entry_capacity;
    char *input;
    size_t input_length;
    size_t input_capacity;
    size_t cursor;
    char *status_text;
    int status_is_error;
    int busy;
    int running;
    int scroll_offset;
    int streaming_assistant_index;
    int streaming_thinking_index;
    /* Note: there is no global streaming_tool_index anymore.
     * Multiple tools run concurrently under psi.sched.run_all and
     * each owns its own placeholder TOOL_RESULT entry tagged with
     * the dispatched tool_call_id; progress/result observers look
     * the entry up by id via psi_tui_find_entry_by_tool_id. */
    /* Redraw coalescing: observer callbacks set transcript_dirty; the
     * host tick hook clears it and repaints. Avoids one redraw per
     * SSE delta; one per sched tick (~every 50ms during a stream). */
    int transcript_dirty;
    int width;
    int height;

    /* Cancellation token read by the HTTP helper thread (curl
     * transfer hook) and the async process poll loop. Main thread
     * triggers it when the user presses Esc. */
    struct psi_abort_signal abort_signal;
};

struct psi_tui_stdio_guard {
    int active;
    int stderr_saved;
    int null_fd;
};

static const long PSI_TUI_MAX_RENDER_TEXT = 8192l;

static int psi_tui_add_entry(
    struct psi_tui_state *state,
    enum psi_tui_entry_kind kind,
    const char *title,
    const char *text,
    int is_error
);
static int psi_tui_build_render_lines(
    struct psi_tui_state *state,
    struct psi_tui_render_line **lines_out,
    size_t *count_out
);
static void psi_tui_render_free_lines(struct psi_tui_render_line *lines, size_t count);
static void psi_tui_redraw(struct psi_tui_state *state);
static void psi_tui_insert_char(struct psi_tui_state *state, int ch);
static void psi_tui_delete_backward(struct psi_tui_state *state);
static void psi_tui_delete_forward(struct psi_tui_state *state);
static void psi_tui_delete_word_backward(struct psi_tui_state *state);
static void psi_tui_delete_word_forward(struct psi_tui_state *state);
static void psi_tui_move_word_backward(struct psi_tui_state *state);
static void psi_tui_move_word_forward(struct psi_tui_state *state);
static void psi_tui_kill_to_end(struct psi_tui_state *state);
static void psi_tui_kill_to_start(struct psi_tui_state *state);
static int psi_tui_start_compact(struct psi_tui_state *state, long keep_recent);

static int psi_tui_transcript_height(const struct psi_tui_state *state) {
    int height;

    if (state == NULL) {
        return 1;
    }
    height = state->height - 6;
    if (height < 1) {
        height = 1;
    }
    return height;
}

static size_t psi_tui_total_rendered_lines(struct psi_tui_state *state);

static int psi_tui_max_scroll_offset(struct psi_tui_state *state) {
    size_t line_count;
    int max_scroll;
    int transcript_height;

    if (state == NULL) {
        return 0;
    }

    line_count = psi_tui_total_rendered_lines(state);
    transcript_height = psi_tui_transcript_height(state);
    max_scroll = (int)line_count - transcript_height;
    if (max_scroll < 0) {
        max_scroll = 0;
    }
    return max_scroll;
}

static void psi_tui_scroll_by(struct psi_tui_state *state, int delta) {
    int next_offset;
    int max_scroll;

    if (state == NULL || delta == 0) {
        return;
    }

    next_offset = state->scroll_offset + delta;
    if (next_offset < 0) {
        next_offset = 0;
    }
    max_scroll = psi_tui_max_scroll_offset(state);
    if (next_offset > max_scroll) {
        next_offset = max_scroll;
    }
    state->scroll_offset = next_offset;
}

static int psi_tui_stdio_guard_begin(struct psi_tui_stdio_guard *guard) {
    if (guard == NULL) {
        return PSI_STATUS_ERROR;
    }

    guard->active = 0;
    guard->stderr_saved = -1;
    guard->null_fd = -1;

    guard->null_fd = open("/dev/null", O_WRONLY);
    if (guard->null_fd < 0) {
        return PSI_STATUS_ERROR;
    }

    guard->stderr_saved = dup(STDERR_FILENO);
    if (guard->stderr_saved < 0) {
        close(guard->null_fd);
        return PSI_STATUS_ERROR;
    }

    if (dup2(guard->null_fd, STDERR_FILENO) < 0) {
        close(guard->stderr_saved);
        close(guard->null_fd);
        return PSI_STATUS_ERROR;
    }

    guard->active = 1;
    return PSI_STATUS_OK;
}

static void psi_tui_stdio_guard_end(struct psi_tui_stdio_guard *guard) {
    if (guard == NULL || !guard->active) {
        return;
    }

    /* Best-effort restore: if dup2 fails the process ends up without
     * a usable stderr, but there is nothing actionable to do from
     * inside curses teardown. Assert visibly in debug builds. */
    if (dup2(guard->stderr_saved, STDERR_FILENO) < 0) {
        /* Intentionally silent: no working stderr to write to. */
    }
    close(guard->stderr_saved);
    close(guard->null_fd);
    guard->active = 0;
    guard->stderr_saved = -1;
    guard->null_fd = -1;
}

static void psi_tui_free_entry(struct psi_tui_entry *entry) {
    if (entry == NULL) {
        return;
    }
    free(entry->title);
    free(entry->text);
    free(entry->tool_call_id);
    entry->title = NULL;
    entry->text = NULL;
    entry->tool_call_id = NULL;
    entry->is_error = 0;
}

static void psi_tui_set_status(struct psi_tui_state *state, const char *text, int is_error) {
    if (state == NULL) {
        return;
    }
    free(state->status_text);
    state->status_text = psi_strdup(text != NULL ? text : "");
    state->status_is_error = is_error;
}

static int psi_tui_reserve_entries(struct psi_tui_state *state, size_t extra) {
    struct psi_tui_entry *next_entries;
    size_t next_capacity;

    if (state->entry_count + extra <= state->entry_capacity) {
        return PSI_STATUS_OK;
    }

    next_capacity = state->entry_capacity == 0u ? 16u : state->entry_capacity;
    while (next_capacity < state->entry_count + extra) {
        next_capacity *= 2u;
    }

    next_entries = (struct psi_tui_entry *)realloc(state->entries, next_capacity * sizeof(struct psi_tui_entry));
    if (next_entries == NULL) {
        return PSI_STATUS_ERROR;
    }

    state->entries = next_entries;
    state->entry_capacity = next_capacity;
    return PSI_STATUS_OK;
}

static int psi_tui_reserve_input(struct psi_tui_state *state, size_t extra) {
    char *next_input;
    size_t next_capacity;

    if (state->input_length + extra + 1u <= state->input_capacity) {
        return PSI_STATUS_OK;
    }

    next_capacity = state->input_capacity == 0u ? 128u : state->input_capacity;
    while (next_capacity < state->input_length + extra + 1u) {
        next_capacity *= 2u;
    }

    next_input = (char *)realloc(state->input, next_capacity);
    if (next_input == NULL) {
        return PSI_STATUS_ERROR;
    }

    state->input = next_input;
    state->input_capacity = next_capacity;
    return PSI_STATUS_OK;
}

static int psi_tui_add_entry(
    struct psi_tui_state *state,
    enum psi_tui_entry_kind kind,
    const char *title,
    const char *text,
    int is_error
) {
    struct psi_tui_entry *entry;

    if (state == NULL) {
        return -1;
    }
    if (psi_tui_reserve_entries(state, 1u) != PSI_STATUS_OK) {
        return -1;
    }

    entry = &state->entries[state->entry_count];
    entry->kind = kind;
    entry->title = psi_strdup(title != NULL ? title : "");
    entry->text = psi_strdup(text != NULL ? text : "");
    entry->is_error = is_error;
    entry->tool_call_id = NULL;
    if (entry->title == NULL || entry->text == NULL) {
        psi_tui_free_entry(entry);
        return -1;
    }

    state->entry_count++;
    return (int)(state->entry_count - 1u);
}

/* Tag the most-recently added entry with a tool-call id. Used right
 * after psi_tui_add_entry to associate TOOL_CALL / TOOL_RESULT
 * pairs with a specific dispatched tool so later progress/result
 * events can find them. A no-op if the entry is gone. */
static void psi_tui_entry_set_tool_id(struct psi_tui_state *state, int index, const char *tool_call_id) {
    if (state == NULL || index < 0 || (size_t)index >= state->entry_count) return;
    if (tool_call_id == NULL) return;
    free(state->entries[index].tool_call_id);
    state->entries[index].tool_call_id = psi_strdup(tool_call_id);
}

/* Walk backwards through the transcript for the most recent entry
 * of `kind` whose tool_call_id matches. Returns -1 when not found.
 * Back-to-front because concurrent tools leave their pair of
 * entries near the tail; earlier occurrences of the same id
 * (e.g. a prior turn's retry) should not match the live one. */
static int psi_tui_find_entry_by_tool_id(
    const struct psi_tui_state *state,
    enum psi_tui_entry_kind kind,
    const char *tool_call_id
) {
    size_t i;
    if (state == NULL || tool_call_id == NULL || state->entry_count == 0u) return -1;
    for (i = state->entry_count; i > 0u; i--) {
        size_t idx = i - 1u;
        const struct psi_tui_entry *e = &state->entries[idx];
        if (e->kind == kind
            && e->tool_call_id != NULL
            && strcmp(e->tool_call_id, tool_call_id) == 0) {
            return (int)idx;
        }
    }
    return -1;
}

static void psi_tui_remove_entry(struct psi_tui_state *state, size_t index) {
    size_t scan;

    if (state == NULL || index >= state->entry_count) {
        return;
    }

    psi_tui_free_entry(&state->entries[index]);
    for (scan = index + 1u; scan < state->entry_count; scan++) {
        state->entries[scan - 1u] = state->entries[scan];
    }
    state->entry_count--;
}

static int psi_tui_append_text(char **text, const char *suffix) {
    size_t current_length;
    size_t suffix_length;
    char *next_text;

    current_length = *text != NULL ? strlen(*text) : 0u;
    suffix_length = suffix != NULL ? strlen(suffix) : 0u;
    next_text = (char *)realloc(*text, current_length + suffix_length + 1u);
    if (next_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *text = next_text;
    if (suffix_length > 0u) {
        memcpy(*text + current_length, suffix, suffix_length);
    }
    (*text)[current_length + suffix_length] = '\0';
    return PSI_STATUS_OK;
}

static char *psi_tui_limit_text(const char *text) {
    size_t length;
    const char *suffix;
    size_t suffix_length;
    char *copy;

    if (text == NULL) {
        return psi_strdup("");
    }

    length = strlen(text);
    if ((long)length <= PSI_TUI_MAX_RENDER_TEXT) {
        return psi_strdup(text);
    }

    suffix = "\n\n[output truncated]";
    suffix_length = strlen(suffix);
    copy = (char *)malloc((size_t)PSI_TUI_MAX_RENDER_TEXT + suffix_length + 1u);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, text, (size_t)PSI_TUI_MAX_RENDER_TEXT);
    memcpy(copy + PSI_TUI_MAX_RENDER_TEXT, suffix, suffix_length);
    copy[PSI_TUI_MAX_RENDER_TEXT + suffix_length] = '\0';
    return copy;
}

static const char *psi_tui_json_string(const cJSON *object, const char *field_name) {
    const cJSON *field;

    field = cJSON_GetObjectItemCaseSensitive((cJSON *)object, field_name);
    if (!cJSON_IsString(field) || field->valuestring == NULL) {
        return NULL;
    }
    return field->valuestring;
}

static long psi_tui_json_long(const cJSON *object, const char *field_name, long fallback) {
    const cJSON *field;

    field = cJSON_GetObjectItemCaseSensitive((cJSON *)object, field_name);
    if (!cJSON_IsNumber(field)) {
        return fallback;
    }
    return (long)field->valuedouble;
}

static char *psi_tui_make_summary2(const char *prefix, const char *value) {
    size_t prefix_length;
    size_t value_length;
    char *text;

    prefix_length = prefix != NULL ? strlen(prefix) : 0u;
    value_length = value != NULL ? strlen(value) : 0u;
    text = (char *)malloc(prefix_length + value_length + 1u);
    if (text == NULL) {
        return NULL;
    }
    if (prefix_length > 0u) {
        memcpy(text, prefix, prefix_length);
    }
    if (value_length > 0u) {
        memcpy(text + prefix_length, value, value_length);
    }
    text[prefix_length + value_length] = '\0';
    return text;
}

static char *psi_tui_make_summary3(const char *a, const char *b, const char *c) {
    size_t a_length;
    size_t b_length;
    size_t c_length;
    char *text;

    a_length = a != NULL ? strlen(a) : 0u;
    b_length = b != NULL ? strlen(b) : 0u;
    c_length = c != NULL ? strlen(c) : 0u;
    text = (char *)malloc(a_length + b_length + c_length + 1u);
    if (text == NULL) {
        return NULL;
    }
    if (a_length > 0u) {
        memcpy(text, a, a_length);
    }
    if (b_length > 0u) {
        memcpy(text + a_length, b, b_length);
    }
    if (c_length > 0u) {
        memcpy(text + a_length + b_length, c, c_length);
    }
    text[a_length + b_length + c_length] = '\0';
    return text;
}

static char *psi_tui_strip_ansi(const char *text) {
    const char *scan;
    char *copy;
    char *out;
    size_t length;

    if (text == NULL) {
        return psi_strdup("");
    }

    length = strlen(text);
    copy = (char *)malloc(length + 1u);
    if (copy == NULL) {
        return NULL;
    }

    scan = text;
    out = copy;
    while (*scan != '\0') {
        if ((unsigned char)scan[0] == 0x1bu && scan[1] == '[') {
            scan += 2;
            while (*scan != '\0' && !((*scan >= '@' && *scan <= '~'))) {
                scan++;
            }
            if (*scan != '\0') {
                scan++;
            }
            continue;
        }
        *out++ = *scan++;
    }
    *out = '\0';
    return copy;
}

static int psi_tui_tool_result_is_error(const char *output_json) {
    cJSON *output;
    const cJSON *ok;
    int is_error;

    output = output_json != NULL ? cJSON_Parse(output_json) : NULL;
    if (output == NULL) {
        return 1;
    }

    ok = cJSON_GetObjectItemCaseSensitive(output, "ok");
    is_error = !(cJSON_IsBool(ok) && cJSON_IsTrue(ok));
    cJSON_Delete(output);
    return is_error;
}

static char *psi_tui_format_tool_call(const char *tool_name, const char *input_json) {
    cJSON *input;
    const char *value;
    char *text;

    input = input_json != NULL ? cJSON_Parse(input_json) : NULL;
    if (strcmp(tool_name, "read") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "path");
        text = psi_tui_make_summary2("read ", value != NULL ? value : "");
    } else if (strcmp(tool_name, "write") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "path");
        text = psi_tui_make_summary2("write ", value != NULL ? value : "");
    } else if (strcmp(tool_name, "edit") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "path");
        text = psi_tui_make_summary2("edit ", value != NULL ? value : "");
    } else if (strcmp(tool_name, "bash") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "command");
        text = psi_tui_make_summary2("bash ", value != NULL ? value : "");
    } else if (strcmp(tool_name, "grep") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "pattern");
        text = psi_tui_make_summary3("grep ", value != NULL ? value : "", "");
    } else if (strcmp(tool_name, "find") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "pattern");
        text = psi_tui_make_summary3("find ", value != NULL ? value : "", "");
    } else if (strcmp(tool_name, "ls") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "path");
        text = psi_tui_make_summary2("ls ", value != NULL ? value : ".");
    } else if (strcmp(tool_name, "lua") == 0 && input != NULL) {
        value = psi_tui_json_string(input, "mode");
        text = psi_tui_make_summary2("lua ", value != NULL ? value : "summary");
    } else {
        text = psi_tui_make_summary3(tool_name, " ", input_json != NULL ? input_json : "");
    }

    cJSON_Delete(input);
    return text != NULL ? text : psi_strdup(tool_name);
}

static char *psi_tui_format_tool_result(const char *tool_name, const char *output_json, int *is_error) {
    cJSON *output;
    const char *value;
    long numeric_value;
    char number_buffer[64];
    char *summary;

    output = output_json != NULL ? cJSON_Parse(output_json) : NULL;
    *is_error = 0;
    if (output == NULL) {
        return psi_strdup(output_json != NULL ? output_json : "");
    }

    if (!cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(output, "ok"))) {
        *is_error = 1;
        value = psi_tui_json_string(output, "error");
        summary = psi_tui_make_summary2("error: ", value != NULL ? value : "unknown error");
        cJSON_Delete(output);
        return summary;
    }

    if (strcmp(tool_name, "read") == 0) {
        value = psi_tui_json_string(output, "text");
        summary = psi_tui_limit_text(value != NULL ? value : "");
        cJSON_Delete(output);
        return summary;
    }
    if (strcmp(tool_name, "bash") == 0 || strcmp(tool_name, "grep") == 0 ||
        strcmp(tool_name, "find") == 0 || strcmp(tool_name, "ls") == 0) {
        value = psi_tui_json_string(output, "output");
        summary = psi_tui_limit_text(value != NULL ? value : "");
        cJSON_Delete(output);
        return summary;
    }
    if (strcmp(tool_name, "write") == 0) {
        value = psi_tui_json_string(output, "path");
        numeric_value = psi_tui_json_long(output, "bytes_written", 0l);
        snprintf(number_buffer, sizeof(number_buffer), " (%ld bytes)", numeric_value);
        summary = psi_tui_make_summary3("wrote ", value != NULL ? value : "", number_buffer);
        cJSON_Delete(output);
        return summary;
    }
    if (strcmp(tool_name, "edit") == 0) {
        value = psi_tui_json_string(output, "path");
        numeric_value = psi_tui_json_long(output, "replacements", 0l);
        snprintf(number_buffer, sizeof(number_buffer), " (%ld replacements)", numeric_value);
        summary = psi_tui_make_summary3("edited ", value != NULL ? value : "", number_buffer);
        cJSON_Delete(output);
        return summary;
    }
    if (strcmp(tool_name, "lua") == 0) {
        value = psi_tui_json_string(output, "result");
        summary = psi_tui_limit_text(value != NULL ? value : "");
        cJSON_Delete(output);
        return summary;
    }

    summary = psi_tui_limit_text(output_json != NULL ? output_json : "");
    cJSON_Delete(output);
    return summary;
}

static char *psi_tui_render_event_text(struct psi_tui_state *state, const char *event_name, cJSON *payload) {
    char *payload_json;
    char *rendered_text;
    char *plain_text;
    char *limited_text;

    if (state == NULL || event_name == NULL || payload == NULL) {
        return NULL;
    }

    payload_json = cJSON_PrintUnformatted(payload);
    if (payload_json == NULL) {
        return NULL;
    }

    rendered_text = NULL;
    if (psi_vm_render_event_json(&state->runtime.vm, event_name, payload_json, &rendered_text) != PSI_STATUS_OK) {
        free(payload_json);
        free(rendered_text);
        return NULL;
    }
    free(payload_json);

    plain_text = psi_tui_strip_ansi(rendered_text);
    free(rendered_text);
    if (plain_text == NULL) {
        return NULL;
    }

    limited_text = psi_tui_limit_text(plain_text);
    free(plain_text);
    return limited_text;
}

static char *psi_tui_render_tool_call_text(
    struct psi_tui_state *state,
    const char *tool_call_id,
    const char *tool_name,
    const char *input_json
) {
    cJSON *payload;
    cJSON *input;
    char *rendered;

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return psi_tui_format_tool_call(tool_name, input_json);
    }

    cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
    cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "tool");
    input = input_json != NULL ? cJSON_Parse(input_json) : NULL;
    if (input == NULL) {
        input = cJSON_CreateObject();
    }
    cJSON_AddItemToObject(payload, "input", input);

    rendered = psi_tui_render_event_text(state, "tool-call", payload);
    cJSON_Delete(payload);
    if (rendered != NULL && rendered[0] != '\0') {
        return rendered;
    }
    free(rendered);
    return psi_tui_format_tool_call(tool_name, input_json);
}

static char *psi_tui_render_tool_result_text(
    struct psi_tui_state *state,
    const char *tool_call_id,
    const char *tool_name,
    const char *output_json,
    int *is_error
) {
    cJSON *payload;
    cJSON *result;
    char *rendered;

    *is_error = psi_tui_tool_result_is_error(output_json);
    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return psi_tui_format_tool_result(tool_name, output_json, is_error);
    }

    cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
    cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "tool");
    result = output_json != NULL ? cJSON_Parse(output_json) : NULL;
    if (result == NULL) {
        result = cJSON_CreateObject();
        if (output_json != NULL) {
            cJSON_AddStringToObject(result, "raw", output_json);
        }
    }
    cJSON_AddItemToObject(payload, "result", result);

    rendered = psi_tui_render_event_text(state, "tool-result", payload);
    cJSON_Delete(payload);
    if (rendered != NULL && rendered[0] != '\0') {
        return rendered;
    }
    free(rendered);
    return psi_tui_format_tool_result(tool_name, output_json, is_error);
}

static int psi_tui_render_reserve(
    struct psi_tui_render_line **lines,
    const size_t *count,
    size_t *capacity,
    size_t extra
) {
    struct psi_tui_render_line *next_lines;
    size_t next_capacity;

    if (*count + extra <= *capacity) {
        return PSI_STATUS_OK;
    }

    next_capacity = *capacity == 0u ? 64u : *capacity;
    while (next_capacity < *count + extra) {
        next_capacity *= 2u;
    }

    next_lines = (struct psi_tui_render_line *)realloc(*lines, next_capacity * sizeof(struct psi_tui_render_line));
    if (next_lines == NULL) {
        return PSI_STATUS_ERROR;
    }

    *lines = next_lines;
    *capacity = next_capacity;
    return PSI_STATUS_OK;
}

static int psi_tui_render_add_line(
    struct psi_tui_render_line **lines,
    size_t *count,
    size_t *capacity,
    const char *text,
    int color_pair,
    int attrs
) {
    struct psi_tui_render_line *line;

    if (psi_tui_render_reserve(lines, count, capacity, 1u) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    line = &(*lines)[*count];
    line->text = psi_strdup(text != NULL ? text : "");
    if (line->text == NULL) {
        return PSI_STATUS_ERROR;
    }
    line->color_pair = color_pair;
    line->attrs = attrs;
    line->is_assistant = 0;
    line->in_code_fence = 0;
    (*count)++;
    return PSI_STATUS_OK;
}

static void psi_tui_render_free_lines(struct psi_tui_render_line *lines, size_t count) {
    size_t index;

    if (lines == NULL) {
        return;
    }
    for (index = 0u; index < count; index++) {
        free(lines[index].text);
    }
    free(lines);
}

static int psi_tui_find_break(const char *text, int width) {
    int index;

    if ((int)strlen(text) <= width) {
        return (int)strlen(text);
    }

    for (index = width; index > 0; index--) {
        if (isspace((unsigned char)text[index])) {
            return index;
        }
    }
    return width;
}

static int psi_tui_line_has_prefix(const char *text, const char *prefix) {
    size_t index;

    if (text == NULL || prefix == NULL) {
        return 0;
    }

    for (index = 0u; prefix[index] != '\0'; index++) {
        if (text[index] != prefix[index]) {
            return 0;
        }
    }
    return 1;
}

static void psi_tui_line_style(
    const struct psi_tui_entry *entry,
    const char *line_text,
    int default_color_pair,
    int default_attrs,
    int *color_pair,
    int *attrs
) {
    *color_pair = default_color_pair;
    *attrs = default_attrs;

    if (entry == NULL || line_text == NULL) {
        return;
    }

    if (entry->kind == PSI_TUI_ENTRY_TOOL_RESULT) {
        /* +/- diff coloring only makes sense for tools whose output
         * IS a unified-diff style block. Anything else that happens
         * to emit markdown / YAML lists starting with "- " would
         * get painted red as if each entry were a removed line.
         * Limit to the two tools that actually produce diffs. */
        int diff_context = (entry->title != NULL
            && (strcmp(entry->title, "write") == 0
                || strcmp(entry->title, "edit") == 0));
        if (diff_context && psi_tui_line_has_prefix(line_text, "+ ")) {
            *color_pair = 5;
            *attrs = A_BOLD;
        } else if (diff_context && psi_tui_line_has_prefix(line_text, "- ")) {
            *color_pair = 6;
            *attrs = A_BOLD;
        } else if (diff_context && psi_tui_line_has_prefix(line_text, "  ")) {
            *color_pair = 7;
            *attrs = A_DIM;
        }
    } else if (entry->kind == PSI_TUI_ENTRY_TOOL_CALL) {
        if (psi_tui_line_has_prefix(line_text, "$ ")) {
            *color_pair = 4;
            *attrs = A_BOLD;
        }
    }
}

/* Return 1 iff the source line at `text` starts (ignoring leading
 * spaces) with a Markdown code-fence marker (``` or ~~~). Used by
 * render_wrapped to toggle fence state across source lines of an
 * assistant entry. */
static int psi_tui_md_is_fence_line(const char *text) {
    int i;
    if (text == NULL) return 0;
    i = 0;
    while (text[i] == ' ') i++;
    if (text[i] == '`' && text[i + 1] == '`' && text[i + 2] == '`') return 1;
    if (text[i] == '~' && text[i + 1] == '~' && text[i + 2] == '~') return 1;
    return 0;
}

static int psi_tui_render_wrapped(
    struct psi_tui_render_line **lines,
    size_t *count,
    size_t *capacity,
    const struct psi_tui_entry *entry,
    const char *prefix_first,
    const char *prefix_rest,
    const char *text,
    int color_pair,
    int attrs,
    int width
) {
    const char *cursor;
    const char *line_start;
    const char *line_end;
    const char *prefix;
    size_t prefix_length;
    int available;
    int break_index;
    char *line_text;
    int line_color_pair;
    int line_attrs;
    int is_assistant;
    int fence_state;

    cursor = text != NULL ? text : "";
    prefix = prefix_first != NULL ? prefix_first : "";
    is_assistant = (entry != NULL && entry->kind == PSI_TUI_ENTRY_ASSISTANT);
    fence_state = 0;
    while (1) {
        int source_line_is_fence;
        int line_fence_flag;

        line_start = cursor;
        line_end = strchr(line_start, '\n');
        if (line_end == NULL) {
            line_end = line_start + strlen(line_start);
        }

        /* Toggle fence state when a new source line BEGINS with ```. The
         * fence line itself renders dim (line_fence_flag=1 below). */
        source_line_is_fence = 0;
        if (is_assistant) {
            /* Copy out just the first chars to check prefix without
             * needing to scan past the newline sentinel. */
            char head[8];
            int head_len;
            head_len = (int)(line_end - line_start);
            if (head_len > (int)sizeof(head) - 1) head_len = (int)sizeof(head) - 1;
            memcpy(head, line_start, (size_t)head_len);
            head[head_len] = '\0';
            source_line_is_fence = psi_tui_md_is_fence_line(head);
        }
        if (source_line_is_fence) {
            line_fence_flag = 1; /* fence marker itself rendered dim */
            fence_state = !fence_state;
        } else {
            line_fence_flag = fence_state;
        }

        while (1) {
            prefix_length = strlen(prefix);
            available = width - (int)prefix_length;
            if (available < 1) {
                available = 1;
            }

            psi_tui_line_style(entry, line_start, color_pair, attrs, &line_color_pair, &line_attrs);

            break_index = psi_tui_find_break(line_start, available);
            line_text = (char *)malloc(prefix_length + (size_t)break_index + 1u);
            if (line_text == NULL) {
                return PSI_STATUS_ERROR;
            }
            memcpy(line_text, prefix, prefix_length);
            if (break_index > 0) {
                memcpy(line_text + prefix_length, line_start, (size_t)break_index);
            }
            line_text[prefix_length + (size_t)break_index] = '\0';
            if (psi_tui_render_add_line(lines, count, capacity, line_text, color_pair, attrs) != PSI_STATUS_OK) {
                free(line_text);
                return PSI_STATUS_ERROR;
            }
            (*lines)[*count - 1u].color_pair = line_color_pair;
            (*lines)[*count - 1u].attrs = line_attrs;
            (*lines)[*count - 1u].is_assistant = is_assistant;
            (*lines)[*count - 1u].in_code_fence = line_fence_flag;
            free(line_text);

            line_start += break_index;
            while (*line_start == ' ') {
                line_start++;
            }
            prefix = prefix_rest != NULL ? prefix_rest : "";
            if (*line_start == '\0' || line_start >= line_end) {
                break;
            }
        }

        if (*line_end == '\0') {
            break;
        }
        cursor = line_end + 1;
        prefix = prefix_rest != NULL ? prefix_rest : "";
        if (*cursor == '\0') {
            if (psi_tui_render_add_line(lines, count, capacity, prefix, color_pair, attrs) != PSI_STATUS_OK) {
                return PSI_STATUS_ERROR;
            }
            break;
        }
    }

    return PSI_STATUS_OK;
}

static int psi_tui_entry_style(
    const struct psi_tui_entry *entry,
    const char **prefix_first,
    const char **prefix_rest,
    int *color_pair,
    int *attrs
) {
    /* Wrap indent policy: for speaker / annotation entries, only the
     * FIRST rendered line carries a prefix — continuation lines flow
     * at column 0 so wrapped messages don't pay a 5–10 column tax.
     * Tool-execution entries are the exception; they keep the
     * ╭─/│/╰─ panel border on every wrapped line because it's the
     * visual frame, not a label.
     *
     * Colour alone (pair + attrs) distinguishes `info` entries now —
     * no `[info]` prefix. `error` and `compaction` keep a first-line
     * label but drop their continuation pad. This matches pi-tui's
     * "backgrounded box" aesthetic more closely without pulling in a
     * full pi-tui framework. */
    switch (entry->kind) {
        case PSI_TUI_ENTRY_USER:
            *prefix_first = "You: ";
            *prefix_rest = "";
            *color_pair = 2;
            *attrs = A_BOLD;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_ASSISTANT:
            *prefix_first = "";
            *prefix_rest = "";
            *color_pair = 3;
            *attrs = 0;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_TOOL_CALL:
            /* Opening corner of a tool-execution panel. tool-result
             * entries continue the panel with a vertical pipe and a
             * closing corner is drawn after their last line (see
             * psi_tui_build_render_lines). */
            *prefix_first = "\xe2\x95\xad\xe2\x94\x80 "; /* ╭─ */
            *prefix_rest  = "\xe2\x94\x82  ";             /* │  */
            *color_pair = 4;
            *attrs = 0;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_TOOL_RESULT:
            *prefix_first = "\xe2\x94\x82  "; /* │  */
            *prefix_rest  = "\xe2\x94\x82  "; /* │  */
            *color_pair = entry->is_error ? 6 : 5;
            *attrs = 0;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_ERROR:
            *prefix_first = "error: ";
            *prefix_rest = "";
            *color_pair = 6;
            *attrs = A_BOLD;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_COMPACTION:
            *prefix_first = "— ";
            *prefix_rest = "";
            *color_pair = 7;
            *attrs = A_BOLD;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_THINKING:
            *prefix_first = "";
            *prefix_rest = "";
            *color_pair = 7;
            *attrs = A_DIM;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_INFO:
        default:
            *prefix_first = "";
            *prefix_rest = "";
            *color_pair = 7;
            *attrs = A_DIM;
            return PSI_STATUS_OK;
    }
}

static int psi_tui_build_render_lines(
    struct psi_tui_state *state,
    struct psi_tui_render_line **lines_out,
    size_t *count_out
) {
    struct psi_tui_render_line *lines;
    size_t count;
    size_t capacity;
    size_t index;
    const char *prefix_first;
    const char *prefix_rest;
    int color_pair;
    int attrs;

    lines = NULL;
    count = 0u;
    capacity = 0u;

    for (index = 0u; index < state->entry_count; index++) {
        const struct psi_tui_entry *entry = &state->entries[index];
        const struct psi_tui_entry *prev = index > 0u ? &state->entries[index - 1u] : NULL;
        const struct psi_tui_entry *next =
            (index + 1u < state->entry_count) ? &state->entries[index + 1u] : NULL;
        int same_panel_as_prev = (prev != NULL
            && prev->kind == PSI_TUI_ENTRY_TOOL_CALL
            && entry->kind == PSI_TUI_ENTRY_TOOL_RESULT)
            || (prev != NULL
                && prev->kind == PSI_TUI_ENTRY_TOOL_RESULT
                && entry->kind == PSI_TUI_ENTRY_TOOL_RESULT);

        /* Inter-entry blank-line separator, except between entries
         * that belong to the same tool-execution panel. */
        if (count > 0u && !same_panel_as_prev
            && psi_tui_render_add_line(&lines, &count, &capacity, "", 0, 0) != PSI_STATUS_OK) {
            psi_tui_render_free_lines(lines, count);
            return PSI_STATUS_ERROR;
        }

        psi_tui_entry_style(entry, &prefix_first, &prefix_rest, &color_pair, &attrs);
        if (psi_tui_render_wrapped(
                &lines,
                &count,
                &capacity,
                entry,
                prefix_first,
                prefix_rest,
                entry->text,
                color_pair,
                attrs,
                state->width
            ) != PSI_STATUS_OK) {
            psi_tui_render_free_lines(lines, count);
            return PSI_STATUS_ERROR;
        }

        /* Close the tool-execution panel with ╰─ when this entry is
         * a tool_result and the NEXT entry doesn't continue it. */
        if (entry->kind == PSI_TUI_ENTRY_TOOL_RESULT
            && (next == NULL || next->kind != PSI_TUI_ENTRY_TOOL_RESULT)) {
            if (psi_tui_render_add_line(&lines, &count, &capacity,
                    "\xe2\x95\xb0\xe2\x94\x80", 4, 0) != PSI_STATUS_OK) {
                /* ╰─ : U+2570 U+2500 */
                psi_tui_render_free_lines(lines, count);
                return PSI_STATUS_ERROR;
            }
        }
    }

    *lines_out = lines;
    *count_out = count;
    return PSI_STATUS_OK;
}

/* Build a small JSON arg string describing the TUI state, used by
 * the Lua helpers psi.tui.status_line and psi.tui.footer_hint. Keeps
 * the C side free of any formatting logic — the Lua side decides
 * what to include (session id, model, usage pct, busy flag, scroll
 * indicator, etc.). Safe to call Lua on the main thread now that
 * the worker thread is gone (commit 17f7de0). */
static void psi_tui_footer_arg_json(
    const struct psi_tui_state *state,
    char *buffer,
    size_t buffer_size
) {
    const char *model;
    model = state->runtime.model != NULL
        ? state->runtime.model : "claude-opus-4-7";
    snprintf(buffer, buffer_size,
             "{\"model\":\"%.96s\",\"busy\":%s,\"scroll\":%d}",
             model,
             state->busy ? "true" : "false",
             state->scroll_offset);
}

static void psi_tui_draw_line(int row, const char *text, int color_pair, int attrs) {
    attr_t attribute;
    int max_width;

    attribute = COLOR_PAIR(color_pair) | attrs;
    move(row, 0);
    clrtoeol();
    if (color_pair > 0 || attrs != 0) {
        attron(attribute);
    }
    max_width = COLS > 1 ? COLS - 1 : 0;
    mvaddnstr(row, 0, text != NULL ? text : "", max_width);
    if (color_pair > 0 || attrs != 0) {
        attroff(attribute);
    }
}

/* Map a single ANSI SGR code to the equivalent ncurses attr + color
 * pair overlay. Supports just the codes that psi.ansi and
 * psi.markdown emit — reset (0), bold (1), dim (2), italic (3, mapped
 * to A_UNDERLINE since ncurses italic support is spotty), underline
 * (4), and foreground colors 31-37 which we map to pre-initialised
 * color pairs (see psi_tui_init_colors). Unknown codes are ignored.
 */
struct psi_tui_ansi_state {
    attr_t attrs;
    int color_pair;
};

static void psi_tui_ansi_apply(struct psi_tui_ansi_state *s, int code) {
    /* Map SGR codes to the pre-initialised ncurses color pairs set
     * up by psi_tui_init_colors: 1=blue, 2=cyan, 3=white, 4=yellow,
     * 5=green, 6=red, 7=default (info). */
    switch (code) {
        case 0:  s->attrs = 0; s->color_pair = 0; break;
        case 1:  s->attrs |= A_BOLD; break;
        case 2:  s->attrs |= A_DIM; break;
        case 3:  s->attrs |= A_UNDERLINE; break; /* italic → underline */
        case 4:  s->attrs |= A_UNDERLINE; break;
        case 31: s->color_pair = 6; break; /* red    */
        case 32: s->color_pair = 5; break; /* green  */
        case 33: s->color_pair = 4; break; /* yellow */
        case 34: s->color_pair = 1; break; /* blue   */
        case 36: s->color_pair = 2; break; /* cyan   */
        case 37: s->color_pair = 3; break; /* white  */
        default: break;
    }
}

/* Draw one line of ANSI-escape-bearing text. Consumes \e[...m SGR
 * codes, updates the current attr, and writes the remaining bytes
 * through ncurses at the tracked column.
 *
 * Pre-existing pair overrides (color_pair argument) are used as the
 * base; they're union'd into the live attrs on every cell. Lines
 * without escapes render identically to psi_tui_draw_line. */
static void psi_tui_draw_ansi_line(int row, const char *text, int base_color_pair) {
    int max_width;
    int len;
    int col;
    int i;
    struct psi_tui_ansi_state st;
    attr_t base;

    max_width = COLS > 1 ? COLS - 1 : 0;
    move(row, 0);
    clrtoeol();
    if (text == NULL) return;

    st.attrs = 0;
    st.color_pair = 0;
    base = base_color_pair > 0 ? COLOR_PAIR(base_color_pair) : 0;

    len = (int)strlen(text);
    col = 0;
    i = 0;
    while (i < len && col < max_width) {
        if (text[i] == 0x1b && i + 1 < len && text[i + 1] == '[') {
            /* Parse ESC [ N ; M ; ... m. Accumulate each code into
             * an unsigned int with a small cap so pathological
             * input like \e[99999999999m can't overflow. Any code
             * over 999 is clamped and the parser treats it as an
             * unknown SGR (ignored by psi_tui_ansi_apply). */
            int j = i + 2;
            unsigned int code = 0u;
            int has_digit = 0;
            while (j < len && text[j] != 'm') {
                if (text[j] >= '0' && text[j] <= '9') {
                    if (code <= 999u) {
                        code = code * 10u + (unsigned int)(text[j] - '0');
                    }
                    has_digit = 1;
                } else if (text[j] == ';') {
                    if (has_digit) psi_tui_ansi_apply(&st, (int)code);
                    code = 0u;
                    has_digit = 0;
                } else {
                    break; /* malformed; bail out */
                }
                j++;
            }
            if (j < len && text[j] == 'm') {
                /* Even a bare \e[m counts as reset */
                if (has_digit) psi_tui_ansi_apply(&st, (int)code);
                else psi_tui_ansi_apply(&st, 0);
                i = j + 1;
                continue;
            }
            /* Malformed escape — drop it and keep going. */
            i = j < len ? j : len;
            continue;
        }

        /* Plain-text span: find the next escape or end-of-string
         * and emit the whole run in one call. Using mvaddnstr on a
         * byte span lets ncurses handle UTF-8 multi-byte sequences
         * correctly instead of corrupting them into mojibake the
         * way an addch-per-byte loop would. Column accounting
         * treats byte count as a conservative upper bound for
         * width; multi-byte characters will still fit within the
         * line because the line was already wrapped on plain
         * bytes upstream. */
        {
            int span_start = i;
            int take;
            attr_t cur;
            int pair;

            while (i < len && text[i] != 0x1b) i++;
            take = i - span_start;
            if (take > max_width - col) take = max_width - col;
            if (take <= 0) continue;

            cur = base | st.attrs;
            pair = st.color_pair > 0 ? st.color_pair : base_color_pair;
            if (pair > 0) cur |= COLOR_PAIR(pair);
            if (cur != 0) attron(cur);
            addnstr(text + span_start, take);
            if (cur != 0) attroff(cur);
            col += take;
            i = span_start + take;
        }
    }
}

static void psi_tui_redraw(struct psi_tui_state *state) {
    struct psi_tui_render_line *lines;
    size_t line_count;
    int header_row;
    int transcript_start;
    int transcript_height;
    int status_row;
    int footer_row1;
    int footer_row2;
    int input_row;
    int bottom_row;
    int first_line;
    size_t index;
    char prompt_buffer[4096];
    int prompt_width;
    int input_start;
    size_t visible_cursor;

    if (state == NULL) {
        return;
    }

    getmaxyx(stdscr, state->height, state->width);
    erase();

    header_row = 0;
    transcript_start = 1;
    status_row = state->height - 5;
    footer_row1 = state->height - 4;
    footer_row2 = state->height - 3;
    input_row = state->height - 2;
    bottom_row = state->height - 1;
    if (status_row < transcript_start) {
        status_row = transcript_start;
    }
    if (footer_row1 < status_row) {
        footer_row1 = status_row;
    }
    if (footer_row2 < footer_row1) {
        footer_row2 = footer_row1;
    }
    if (input_row < footer_row2) {
        input_row = footer_row2;
    }
    if (bottom_row < input_row) {
        bottom_row = input_row;
    }
    transcript_height = status_row - transcript_start;
    if (transcript_height < 1) {
        transcript_height = 1;
    }

    psi_tui_draw_line(header_row, "psi coding agent", 1, A_BOLD);

    lines = NULL;
    line_count = 0u;
    if (psi_tui_build_render_lines(state, &lines, &line_count) == PSI_STATUS_OK) {
        int max_scroll;

        max_scroll = (int)line_count - transcript_height;
        if (max_scroll < 0) {
            max_scroll = 0;
        }
        if (state->scroll_offset > max_scroll) {
            state->scroll_offset = max_scroll;
        }
        first_line = (int)line_count - transcript_height - state->scroll_offset;
        if (first_line < 0) {
            first_line = 0;
        }
        for (index = 0u; index < (size_t)transcript_height; index++) {
            int source_index;
            source_index = first_line + (int)index;
            if (source_index >= 0 && source_index < (int)line_count) {
                if (lines[source_index].is_assistant) {
                    /* Run the wrapped plain-text line through the
                     * pure-Lua markdown renderer, then draw the
                     * ANSI-escape output through the C parser. Safe
                     * to call Lua from the redraw path now that
                     * there is no worker thread holding lua_State
                     * (single-thread model, stage 5). */
                    char *styled = NULL;
                    psi_vm_markdown_render_line(
                        &state->runtime.vm,
                        lines[source_index].text,
                        lines[source_index].in_code_fence,
                        &styled);
                    psi_tui_draw_ansi_line(
                        transcript_start + (int)index,
                        styled != NULL ? styled : lines[source_index].text,
                        3);
                    free(styled);
                } else {
                    psi_tui_draw_line(
                        transcript_start + (int)index,
                        lines[source_index].text,
                        lines[source_index].color_pair,
                        lines[source_index].attrs
                    );
                }
            } else {
                psi_tui_draw_line(transcript_start + (int)index, "", 0, 0);
            }
        }
    }
    psi_tui_render_free_lines(lines, line_count);

    {
        char arg_json[256];
        char *hint = NULL;
        char *status_line = NULL;
        char cwd_buffer[4096];
        const char *cwd;

        psi_tui_footer_arg_json(state, arg_json, sizeof(arg_json));

        /* status_text (set by operations via psi_tui_set_status)
         * wins over the regular Lua-rendered hint; otherwise we
         * defer to psi.tui.footer_hint. */
        if (state->status_text != NULL) {
            psi_tui_draw_line(
                status_row, state->status_text,
                state->status_is_error ? 6 : 7,
                state->status_is_error ? A_BOLD : A_DIM
            );
        } else {
            psi_vm_tui_footer_hint(&state->runtime.vm, arg_json, &hint);
            psi_tui_draw_line(
                status_row, hint != NULL ? hint : "",
                7, A_DIM
            );
            free(hint);
        }

        cwd = getcwd(cwd_buffer, sizeof(cwd_buffer));
        if (cwd == NULL) {
            snprintf(cwd_buffer, sizeof(cwd_buffer),
                     "<cwd unavailable: %s>", strerror(errno));
        }
        psi_tui_draw_line(footer_row1, cwd_buffer, 7, A_DIM);

        psi_vm_tui_status_line(&state->runtime.vm, arg_json, &status_line);
        psi_tui_draw_line(footer_row2, status_line != NULL ? status_line : "",
                          7, A_DIM);
        free(status_line);
    }

    prompt_width = state->width - 3;
    if (prompt_width < 1) {
        prompt_width = 1;
    }
    input_start = 0;
    if ((int)state->cursor >= prompt_width) {
        input_start = (int)state->cursor - prompt_width + 1;
    }
    snprintf(prompt_buffer, sizeof(prompt_buffer), "> %s", state->input != NULL ? state->input + input_start : "");
    psi_tui_draw_line(input_row, prompt_buffer, 2, A_BOLD);
    psi_tui_draw_line(bottom_row, "", 0, 0);

    {
        int cursor_col;

        curs_set(1);
        visible_cursor = state->cursor - (size_t)input_start;
        cursor_col = 2 + (int)visible_cursor;
        if (cursor_col > state->width - 2) {
            cursor_col = state->width - 2;
        }
        if (cursor_col < 0) {
            cursor_col = 0;
        }
        move(input_row, cursor_col);
    }

    refresh();
}

static void psi_tui_append_entry_text(struct psi_tui_state *state, int index, const char *text) {
    if (state == NULL || index < 0 || (size_t)index >= state->entry_count || text == NULL) {
        return;
    }
    (void)psi_tui_append_text(&state->entries[index].text, text);
}

/* Dry-run version of psi_tui_render_wrapped's wrap-iteration that
 * returns only the line count — no string allocation, no render_line
 * struct, no Lua calls. Used by the scroll-anchor helpers which need
 * a before/after delta but never look at the lines themselves.
 *
 * Replicates the break-search in psi_tui_find_break exactly so the
 * count matches what build_render_lines would have produced. */
static size_t psi_tui_count_wrapped(
    const char *text,
    const char *prefix_first,
    const char *prefix_rest,
    int width
) {
    size_t count;
    const char *cursor;
    const char *line_start;
    const char *line_end;
    const char *prefix;
    size_t prefix_length;
    int available;
    int break_index;

    count = 0u;
    cursor = text != NULL ? text : "";
    prefix = prefix_first != NULL ? prefix_first : "";

    while (1) {
        line_start = cursor;
        line_end = strchr(line_start, '\n');
        if (line_end == NULL) line_end = line_start + strlen(line_start);

        while (1) {
            prefix_length = strlen(prefix);
            available = width - (int)prefix_length;
            if (available < 1) available = 1;
            break_index = psi_tui_find_break(line_start, available);
            count++;
            line_start += break_index;
            while (*line_start == ' ') line_start++;
            prefix = prefix_rest != NULL ? prefix_rest : "";
            if (*line_start == '\0' || line_start >= line_end) break;
        }

        if (*line_end == '\0') break;
        cursor = line_end + 1;
        prefix = prefix_rest != NULL ? prefix_rest : "";
        if (*cursor == '\0') {
            count++;
            break;
        }
    }
    return count;
}

/* Count the total rendered line count for the current transcript.
 * Walks state->entries dry-run (no allocations, no Lua) so callers
 * can use it on the redraw hot path without paying O(total lines)
 * of malloc/free every scroll-anchor check. */
static size_t psi_tui_total_rendered_lines(struct psi_tui_state *state) {
    size_t total;
    size_t index;
    const char *prefix_first;
    const char *prefix_rest;
    int color_pair;
    int attrs;

    if (state == NULL) return 0u;
    total = 0u;
    for (index = 0u; index < state->entry_count; index++) {
        const struct psi_tui_entry *entry = &state->entries[index];
        const struct psi_tui_entry *prev = index > 0u ? &state->entries[index - 1u] : NULL;
        const struct psi_tui_entry *next =
            (index + 1u < state->entry_count) ? &state->entries[index + 1u] : NULL;
        int same_panel_as_prev = (prev != NULL
            && prev->kind == PSI_TUI_ENTRY_TOOL_CALL
            && entry->kind == PSI_TUI_ENTRY_TOOL_RESULT)
            || (prev != NULL
                && prev->kind == PSI_TUI_ENTRY_TOOL_RESULT
                && entry->kind == PSI_TUI_ENTRY_TOOL_RESULT);
        if (total > 0u && !same_panel_as_prev) total++;

        psi_tui_entry_style(entry, &prefix_first, &prefix_rest, &color_pair, &attrs);
        total += psi_tui_count_wrapped(entry->text, prefix_first, prefix_rest, state->width);

        /* build_render_lines emits a closing ╰─ after the last
         * tool_result of a panel. Mirror that here. */
        if (entry->kind == PSI_TUI_ENTRY_TOOL_RESULT
            && (next == NULL || next->kind != PSI_TUI_ENTRY_TOOL_RESULT)) {
            total++;
        }
    }
    return total;
}

/* Anchor-scroll helper: when the user has scrolled up to read older
 * transcript, keep their view locked to the same content as new
 * deltas land. Call before_mutation() to snapshot line-count, then
 * after_mutation() to re-anchor. No-op when scroll_offset==0. */
static size_t psi_tui_scroll_anchor_before(struct psi_tui_state *state) {
    if (state == NULL || state->scroll_offset <= 0) return 0u;
    return psi_tui_total_rendered_lines(state);
}

static void psi_tui_scroll_anchor_after(struct psi_tui_state *state, size_t lines_before) {
    size_t lines_after;
    if (state == NULL || lines_before == 0u || state->scroll_offset <= 0) return;
    lines_after = psi_tui_total_rendered_lines(state);
    if (lines_after > lines_before) {
        state->scroll_offset += (int)(lines_after - lines_before);
    }
}

/* Observer callbacks (run on the single Lua/main thread from inside
 * the provider's streaming coroutine). They mutate state->entries[]
 * directly and flag the transcript dirty; the host tick hook runs
 * during sched resumes and repaints when the flag is set. No queue,
 * no mutex, no background thread — all pre-2027d56 races are gone
 * by construction.
 */

static void psi_tui_finish_streaming_assistant(struct psi_tui_state *state) {
    if (state == NULL || state->streaming_assistant_index < 0) {
        return;
    }
    if ((size_t)state->streaming_assistant_index < state->entry_count &&
        state->entries[state->streaming_assistant_index].text != NULL &&
        state->entries[state->streaming_assistant_index].text[0] == '\0') {
        psi_tui_remove_entry(state, (size_t)state->streaming_assistant_index);
    }
    state->streaming_assistant_index = -1;
}

static void psi_tui_observer_text_delta(void *userdata, const char *text) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    size_t lines_before;
    if (state == NULL || text == NULL) return;
    lines_before = psi_tui_scroll_anchor_before(state);
    state->streaming_thinking_index = -1;
    if (state->streaming_assistant_index < 0) {
        state->streaming_assistant_index =
            psi_tui_add_entry(state, PSI_TUI_ENTRY_ASSISTANT, NULL, "", 0);
    }
    psi_tui_append_entry_text(state, state->streaming_assistant_index, text);
    psi_tui_scroll_anchor_after(state, lines_before);
    state->transcript_dirty = 1;
}

static void psi_tui_observer_thinking_delta(void *userdata, const char *text) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    size_t lines_before;
    if (state == NULL || text == NULL || text[0] == '\0') return;
    lines_before = psi_tui_scroll_anchor_before(state);
    if (state->streaming_thinking_index < 0) {
        state->streaming_thinking_index =
            psi_tui_add_entry(state, PSI_TUI_ENTRY_THINKING, NULL, "", 0);
    }
    psi_tui_append_entry_text(state, state->streaming_thinking_index, text);
    psi_tui_scroll_anchor_after(state, lines_before);
    state->transcript_dirty = 1;
}

/* When a tool dispatch fires, add BOTH the TOOL_CALL header and
 * an empty TOOL_RESULT placeholder tagged with the same
 * tool_call_id. This "reserves" a panel per tool so that when
 * progress chunks start arriving — for this tool specifically —
 * we can route them to the right entry instead of smearing
 * everyone's output into a shared streaming block. Matters for
 * concurrent dispatch (sched.run_all) where three shell commands
 * could otherwise interleave their output unrecognisably. */
static void psi_tui_observer_tool_call(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    char *summary;
    size_t lines_before;
    int call_idx;
    int result_idx;
    if (state == NULL || tool_name == NULL) return;
    summary = psi_tui_render_tool_call_text(state, tool_call_id, tool_name, input_json);
    lines_before = psi_tui_scroll_anchor_before(state);
    psi_tui_finish_streaming_assistant(state);
    state->streaming_thinking_index = -1;

    call_idx = psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_CALL, tool_name,
                                 summary != NULL ? summary : "", 0);
    psi_tui_entry_set_tool_id(state, call_idx, tool_call_id);
    /* Placeholder that tool_progress / tool_result will fill in. */
    result_idx = psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT, NULL, "", 0);
    psi_tui_entry_set_tool_id(state, result_idx, tool_call_id);

    free(summary);
    psi_tui_scroll_anchor_after(state, lines_before);
    state->transcript_dirty = 1;
}

static void psi_tui_observer_tool_progress(void *userdata, const char *tool_call_id, const char *chunk, size_t len) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    size_t lines_before;
    int idx;
    char *copy;
    if (state == NULL || chunk == NULL || len == 0u) return;
    copy = (char *)malloc(len + 1u);
    if (copy == NULL) return;
    memcpy(copy, chunk, len);
    copy[len] = '\0';
    lines_before = psi_tui_scroll_anchor_before(state);

    idx = psi_tui_find_entry_by_tool_id(state, PSI_TUI_ENTRY_TOOL_RESULT, tool_call_id);
    if (idx < 0) {
        /* No placeholder exists (maybe the session was replayed
         * without a live tool_call event). Fall back to appending
         * a fresh untagged result entry so nothing gets lost. */
        idx = psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT, NULL, "", 0);
        psi_tui_entry_set_tool_id(state, idx, tool_call_id);
    }
    psi_tui_append_entry_text(state, idx, copy);
    free(copy);

    psi_tui_scroll_anchor_after(state, lines_before);
    state->transcript_dirty = 1;
}

static void psi_tui_observer_tool_result(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    char *summary;
    int is_error;
    size_t lines_before;
    int idx;
    if (state == NULL || tool_name == NULL) return;
    summary = psi_tui_render_tool_result_text(state, tool_call_id, tool_name, output_json, &is_error);
    lines_before = psi_tui_scroll_anchor_before(state);

    idx = psi_tui_find_entry_by_tool_id(state, PSI_TUI_ENTRY_TOOL_RESULT, tool_call_id);
    if (idx >= 0) {
        /* Replace the placeholder / streaming body with the
         * final formatted tool_result render. */
        struct psi_tui_entry *entry = &state->entries[idx];
        free(entry->title);
        free(entry->text);
        entry->title = psi_strdup(tool_name);
        entry->text = summary != NULL ? summary : psi_strdup("");
        entry->is_error = is_error;
        summary = NULL; /* ownership moved into entry->text */
    } else {
        idx = psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT, tool_name,
                                summary != NULL ? summary : "", is_error);
        psi_tui_entry_set_tool_id(state, idx, tool_call_id);
    }
    free(summary);

    psi_tui_scroll_anchor_after(state, lines_before);
    state->transcript_dirty = 1;
}

static void psi_tui_add_session_entry(struct psi_tui_state *state, const struct psi_message *message) {
    cJSON *parsed;
    cJSON *payload;
    cJSON *input_json;
    cJSON *result_json;
    cJSON *content_array;
    cJSON *block;
    cJSON *type_field;
    const char *tool_call_id;
    const char *tool_name;
    char *summary;
    int is_error;

    if (state == NULL || message == NULL) {
        return;
    }

    switch (message->role) {
        case PSI_MESSAGE_USER:
            psi_tui_add_entry(state, PSI_TUI_ENTRY_USER, NULL, message->text, 0);
            break;
        case PSI_MESSAGE_ASSISTANT:
            if (message->text != NULL && message->text[0] != '\0') {
                psi_tui_add_entry(state, PSI_TUI_ENTRY_ASSISTANT, NULL, message->text, 0);
            }
            /* Mirror pi: tool calls live inside the assistant message's
             * content array. Walk the stored data_json and synthesize a
             * tool-call entry for every tool_use block. */
            if (message->data_json != NULL) {
                content_array = cJSON_Parse(message->data_json);
                cJSON_ArrayForEach(block, content_array) {
                    type_field = cJSON_GetObjectItemCaseSensitive(block, "type");
                    if (type_field == NULL || !cJSON_IsString(type_field)) continue;
                    if (strcmp(type_field->valuestring, "tool_use") != 0) continue;
                    tool_call_id = psi_tui_json_string(block, "id");
                    tool_name = psi_tui_json_string(block, "name");
                    input_json = cJSON_GetObjectItemCaseSensitive(block, "input");
                    payload = cJSON_CreateObject();
                    if (payload == NULL) continue;
                    cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
                    cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "tool");
                    cJSON_AddItemToObject(payload, "input",
                        input_json != NULL ? cJSON_Duplicate(input_json, 1) : cJSON_CreateObject());
                    summary = psi_tui_render_event_text(state, "tool-call", payload);
                    cJSON_Delete(payload);
                    if (summary == NULL || summary[0] == '\0') {
                        free(summary);
                        summary = psi_tui_format_tool_call(
                            tool_name != NULL ? tool_name : "tool", NULL);
                    }
                    if (summary != NULL) {
                        psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_CALL, tool_name, summary, 0);
                        free(summary);
                    }
                }
                cJSON_Delete(content_array);
            }
            break;
        case PSI_MESSAGE_TOOL_CALL:
            /* Legacy role: no longer written by the agent loop. Ignored
             * on replay — tool calls are reconstructed from the
             * assistant message's content blocks above. */
            break;
        case PSI_MESSAGE_TOOL_RESULT:
            parsed = message->text != NULL ? cJSON_Parse(message->text) : NULL;
            tool_call_id = parsed != NULL ? psi_tui_json_string(parsed, "tool_use_id") : NULL;
            tool_name = parsed != NULL ? psi_tui_json_string(parsed, "tool") : NULL;
            result_json = parsed != NULL ? cJSON_Parse(psi_tui_json_string(parsed, "content")) : NULL;
            payload = cJSON_CreateObject();
            if (payload != NULL) {
                cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
                cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "tool");
                cJSON_AddItemToObject(payload, "result", result_json != NULL ? result_json : cJSON_CreateObject());
                result_json = NULL;
                summary = psi_tui_render_event_text(state, "tool-result", payload);
                cJSON_Delete(payload);
            } else {
                summary = NULL;
            }
            cJSON_Delete(result_json);
            is_error = parsed != NULL && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(parsed, "is_error"));
            if (summary == NULL || summary[0] == '\0') {
                free(summary);
                summary = psi_tui_format_tool_result(
                    tool_name != NULL ? tool_name : "tool",
                    parsed != NULL ? psi_tui_json_string(parsed, "content") : message->text,
                    &is_error
                );
            }
            cJSON_Delete(parsed);
            if (summary != NULL) {
                psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT, tool_name, summary, is_error);
                free(summary);
            }
            break;
        case PSI_MESSAGE_COMPACTION_SUMMARY:
            psi_tui_add_entry(state, PSI_TUI_ENTRY_COMPACTION, NULL, message->text, 0);
            break;
        case PSI_MESSAGE_BRANCH_SUMMARY:
        case PSI_MESSAGE_CUSTOM:
        default:
            if (message->text != NULL && message->text[0] != '\0') {
                psi_tui_add_entry(state, PSI_TUI_ENTRY_INFO, NULL, message->text, 0);
            }
            break;
    }
}

static void psi_tui_rebuild_from_session(struct psi_tui_state *state) {
    size_t index;

    if (state == NULL) {
        return;
    }

    for (index = 0u; index < state->entry_count; index++) {
        psi_tui_free_entry(&state->entries[index]);
    }
    state->entry_count = 0u;
    state->streaming_assistant_index = -1;

    for (index = 0u; index < state->runtime.session.count; index++) {
        psi_tui_add_session_entry(state, &state->runtime.session.messages[index]);
    }
    state->scroll_offset = 0;
}

static int psi_tui_handle_command(struct psi_tui_state *state, const char *line) {
    char *action_name;
    char *action_text;
    long keep_recent;
    int status;

    action_name = NULL;
    action_text = NULL;
    keep_recent = 0l;

    if (strcmp(line, "/quit") == 0 || strcmp(line, "/q") == 0 ||
        strcmp(line, ":quit") == 0 || strcmp(line, ":q") == 0) {
        state->running = 0;
        return PSI_STATUS_OK;
    }

    status = psi_vm_parse_command(&state->runtime.vm, line, &action_name, &action_text, &keep_recent);
    if (status != PSI_STATUS_OK) {
        psi_tui_set_status(state, "failed to parse command", 1);
        free(action_name);
        free(action_text);
        return PSI_STATUS_ERROR;
    }

    if (action_name != NULL && strcmp(action_name, "print") == 0) {
        /* Commands with purely side effects (/new, /clear, /reload,
         * /copy, /session, /export, /name, /system-prompt, /help) all
         * route through "print"; commands.lua has already performed
         * the mutation by the time we see this. Re-render the
         * transcript so entries cleared by /new or /clear disappear. */
        psi_tui_rebuild_from_session(state);
        psi_tui_add_entry(state, PSI_TUI_ENTRY_INFO, NULL, action_text != NULL ? action_text : "", 0);
        state->scroll_offset = 0;
        psi_tui_set_status(state, "", 0);
    } else if (action_name != NULL && strcmp(action_name, "compact") == 0) {
        status = psi_tui_start_compact(state, keep_recent);
    } else {
        psi_tui_set_status(state, "unknown command", 1);
    }

    free(action_name);
    free(action_text);
    return status;
}

/* Host tick hook (called from psi.sched between coroutine resumes).
 *
 * Runs one short iteration of the TUI event loop: drain any queued
 * input non-blockingly, then repaint if observers or input dispatch
 * marked the transcript dirty. Must be cheap: it fires every time
 * the agent coroutine yields (each SSE chunk, between tool calls,
 * during shell waits). The input branch is kept minimal — Esc,
 * scroll, resize, and Ctrl-L only; full keyboard editing is for
 * the idle main loop.
 */
static void psi_tui_input_once(struct psi_tui_state *state, int ch);

static void psi_tui_tick(void *userdata) {
    struct psi_tui_state *state = (struct psi_tui_state *)userdata;
    int prev_timeout;
    int ch;

    if (state == NULL) return;

    /* Poll any keys waiting in the input queue without blocking. */
    prev_timeout = 0; /* we set it explicitly below */
    (void)prev_timeout;
    wtimeout(stdscr, 0);
    for (;;) {
        ch = getch();
        if (ch == ERR) break;
        psi_tui_input_once(state, ch);
    }

    if (state->transcript_dirty) {
        state->transcript_dirty = 0;
        psi_tui_redraw(state);
    }
}

/* Lightweight input dispatch used by the tick hook during a turn.
 * Supports abort (Esc), scroll, resize, full-redraw, Ctrl-Z, and
 * input editing. Enter submits are gated off while busy. */
static void psi_tui_submit_if_idle(struct psi_tui_state *state); /* fwd */

static void psi_tui_input_once(struct psi_tui_state *state, int ch) {
    if (state == NULL) return;

    if (ch == KEY_RESIZE) {
        clearok(stdscr, TRUE);
        state->transcript_dirty = 1;
        return;
    }
    if (ch == KEY_PPAGE) {
        psi_tui_scroll_by(state, state->height > 8 ? state->height / 2 : 4);
        state->transcript_dirty = 1;
        return;
    }
    if (ch == KEY_NPAGE) {
        psi_tui_scroll_by(state, -(state->height > 8 ? state->height / 2 : 4));
        state->transcript_dirty = 1;
        return;
    }
    if (ch == KEY_UP) {
        psi_tui_scroll_by(state, 1);
        state->transcript_dirty = 1;
        return;
    }
    if (ch == KEY_DOWN) {
        psi_tui_scroll_by(state, -1);
        state->transcript_dirty = 1;
        return;
    }
    if (ch == 27) { /* Esc — aborts the turn while busy */
        if (state->busy) {
            psi_abort_signal_trigger(&state->abort_signal);
            psi_tui_set_status(state, "aborting...", 0);
            state->transcript_dirty = 1;
        }
        return;
    }
    if (ch == 12) { /* Ctrl-L */
        clearok(stdscr, TRUE);
        state->transcript_dirty = 1;
        return;
    }
    /* Input editing — allowed while busy so the user can compose
     * the next message. Enter submit is gated by busy inside submit. */
    if (ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
        psi_tui_delete_backward(state);
        state->transcript_dirty = 1;
        return;
    }
    if (ch == 4) { /* Ctrl-D forward-delete */
        if (state->input_length > 0u) {
            psi_tui_delete_forward(state);
            state->transcript_dirty = 1;
        }
        return;
    }
    if (ch == 23) { psi_tui_delete_word_backward(state); state->transcript_dirty = 1; return; }
    if (ch == 11) { psi_tui_kill_to_end(state); state->transcript_dirty = 1; return; }
    if (ch == 21) { psi_tui_kill_to_start(state); state->transcript_dirty = 1; return; }
    if (ch == KEY_LEFT || ch == 2)  { if (state->cursor > 0u) state->cursor--; state->transcript_dirty = 1; return; }
    if (ch == KEY_RIGHT || ch == 6) { if (state->cursor < state->input_length) state->cursor++; state->transcript_dirty = 1; return; }
    if (ch == KEY_HOME || ch == 1)  { state->cursor = 0u; state->transcript_dirty = 1; return; }
    if (ch == KEY_END  || ch == 5)  { state->cursor = state->input_length; state->transcript_dirty = 1; return; }
    if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
        /* Gate inside submit_if_idle — while busy, just ignore. */
        psi_tui_submit_if_idle(state);
        state->transcript_dirty = 1;
        return;
    }
    if (isprint(ch)) {
        psi_tui_insert_char(state, ch);
        state->transcript_dirty = 1;
    }
}

/* Run an agent turn synchronously on the main thread.
 *
 * The provider loop (psi.anthropic / psi.ollama run_turn) now runs
 * inside a Lua coroutine (set up by psi.agent.run_turn via sched).
 * Every cooperative yield point inside the provider — each SSE
 * chunk poll, every tool poll — calls psi.host_tick, which
 * dispatches to psi_tui_tick above so the UI keeps repainting and
 * the user can press Esc. By the time this function returns the
 * turn is fully complete and the session is persisted. */
static int psi_tui_run_turn_sync(struct psi_tui_state *state, const char *line) {
    struct psi_agent_observer observer;
    struct psi_tui_stdio_guard stdio_guard;
    struct psi_host_context *host;
    char *response_text;
    int status;

    memset(&observer, 0, sizeof(observer));
    observer.userdata = state;
    observer.on_assistant_text_delta = psi_tui_observer_text_delta;
    observer.on_tool_call = psi_tui_observer_tool_call;
    observer.on_tool_result = psi_tui_observer_tool_result;
    observer.on_tool_progress = psi_tui_observer_tool_progress;
    observer.on_thinking_delta = psi_tui_observer_thinking_delta;

    host = &state->runtime.vm.host;
    host->tick_hook = psi_tui_tick;
    host->tick_userdata = state;

    response_text = NULL;
    stdio_guard.active = 0;
    status = psi_tui_stdio_guard_begin(&stdio_guard);
    if (status == PSI_STATUS_OK) {
        status = psi_agent_runtime_turn_with_observer(
            &state->runtime, line, &observer,
            &state->abort_signal, &response_text);
        psi_tui_stdio_guard_end(&stdio_guard);
    }

    host->tick_hook = NULL;
    host->tick_userdata = NULL;

    if (status == PSI_STATUS_OK) {
        if (psi_agent_runtime_save(&state->runtime) != PSI_STATUS_OK) {
            psi_tui_finish_streaming_assistant(state);
            psi_tui_set_status(state, "failed to save session file", 1);
        } else {
            psi_tui_finish_streaming_assistant(state);
            psi_tui_set_status(state, "", 0);
        }
    } else {
        /* The Lua turn loop returns the classified error message as
         * response_text on failure (see openai_compat.classify_http_error
         * / anthropic.lua). Use that directly so the transcript shows
         * the real reason — "429 — rate limited — retry after a
         * moment" — instead of a generic banner. Fall back to a
         * placeholder when response_text is empty (e.g. begin() itself
         * failed before the stream started). */
        const char *detail = (response_text != NULL && response_text[0] != '\0')
                             ? response_text
                             : "provider request failed";
        psi_tui_set_status(state, "agent turn failed", 1);
        psi_tui_finish_streaming_assistant(state);
        psi_tui_add_entry(state, PSI_TUI_ENTRY_ERROR, NULL, detail, 1);
    }
    free(response_text);

    state->streaming_assistant_index = -1;
    state->streaming_thinking_index = -1;
    return status;
}

static int psi_tui_run_compact_sync(struct psi_tui_state *state, long keep_recent) {
    struct psi_tui_stdio_guard stdio_guard;
    struct psi_host_context *host;
    char *summary;
    int status;

    host = &state->runtime.vm.host;
    host->tick_hook = psi_tui_tick;
    host->tick_userdata = state;

    summary = NULL;
    stdio_guard.active = 0;
    status = psi_tui_stdio_guard_begin(&stdio_guard);
    if (status == PSI_STATUS_OK) {
        status = psi_agent_runtime_compact(
            &state->runtime, (size_t)keep_recent,
            &state->abort_signal, &summary);
        psi_tui_stdio_guard_end(&stdio_guard);
    }

    host->tick_hook = NULL;
    host->tick_userdata = NULL;

    if (status == PSI_STATUS_OK) {
        if (psi_agent_runtime_save(&state->runtime) != PSI_STATUS_OK) {
            psi_tui_set_status(state, "failed to save compacted session", 1);
        } else {
            psi_tui_rebuild_from_session(state);
            psi_tui_set_status(state, "session compacted", 0);
        }
    } else {
        psi_tui_set_status(state, "failed to compact session", 1);
    }
    free(summary);
    return status;
}

static int psi_tui_submit(struct psi_tui_state *state) {
    char *line;
    int status;

    if (state == NULL || state->busy || state->input_length == 0u) {
        return PSI_STATUS_OK;
    }

    line = psi_strdup(state->input);
    if (line == NULL) return PSI_STATUS_ERROR;

    state->input[0] = '\0';
    state->input_length = 0u;
    state->cursor = 0u;

    if (line[0] == '/') {
        status = psi_tui_handle_command(state, line);
        free(line);
        return status;
    }

    psi_tui_add_entry(state, PSI_TUI_ENTRY_USER, NULL, line, 0);
    state->streaming_assistant_index = psi_tui_add_entry(state, PSI_TUI_ENTRY_ASSISTANT, NULL, "", 0);
    state->scroll_offset = 0;
    state->busy = 1;
    psi_abort_signal_reset(&state->abort_signal);
    psi_tui_set_status(state, "Working...", 0);
    psi_tui_redraw(state);

    (void)psi_tui_run_turn_sync(state, line);
    free(line);

    state->busy = 0;
    psi_tui_redraw(state);
    return PSI_STATUS_OK;
}

static void psi_tui_submit_if_idle(struct psi_tui_state *state) {
    if (state == NULL || state->busy) return;
    (void)psi_tui_submit(state);
}

static int psi_tui_start_compact(struct psi_tui_state *state, long keep_recent) {
    int status;
    if (state == NULL || state->busy) return PSI_STATUS_OK;
    state->busy = 1;
    psi_abort_signal_reset(&state->abort_signal);
    psi_tui_set_status(state, "Compacting...", 0);
    psi_tui_redraw(state);
    status = psi_tui_run_compact_sync(state, keep_recent);
    state->busy = 0;
    psi_tui_redraw(state);
    return status;
}

static void psi_tui_insert_char(struct psi_tui_state *state, int ch) {
    if (psi_tui_reserve_input(state, 1u) != PSI_STATUS_OK) {
        return;
    }
    memmove(
        state->input + state->cursor + 1u,
        state->input + state->cursor,
        state->input_length - state->cursor + 1u
    );
    state->input[state->cursor] = (char)ch;
    state->input_length++;
    state->cursor++;
}

static void psi_tui_delete_backward(struct psi_tui_state *state) {
    if (state->cursor == 0u || state->input_length == 0u) {
        return;
    }
    memmove(
        state->input + state->cursor - 1u,
        state->input + state->cursor,
        state->input_length - state->cursor + 1u
    );
    state->cursor--;
    state->input_length--;
}

static void psi_tui_delete_forward(struct psi_tui_state *state) {
    if (state->cursor >= state->input_length) {
        return;
    }
    memmove(
        state->input + state->cursor,
        state->input + state->cursor + 1u,
        state->input_length - state->cursor
    );
    state->input_length--;
}

static void psi_tui_delete_word_backward(struct psi_tui_state *state) {
    size_t start;

    if (state->cursor == 0u) {
        return;
    }

    start = state->cursor;
    while (start > 0u && isspace((unsigned char)state->input[start - 1u])) {
        start--;
    }
    while (start > 0u && !isspace((unsigned char)state->input[start - 1u])) {
        start--;
    }
    memmove(
        state->input + start,
        state->input + state->cursor,
        state->input_length - state->cursor + 1u
    );
    state->input_length -= state->cursor - start;
    state->cursor = start;
}

/* Readline Alt-D: delete from cursor to end of current word. */
static void psi_tui_delete_word_forward(struct psi_tui_state *state) {
    size_t end;

    if (state == NULL || state->input == NULL) return;
    if (state->cursor >= state->input_length) return;

    end = state->cursor;
    /* skip leading whitespace */
    while (end < state->input_length && isspace((unsigned char)state->input[end])) {
        end++;
    }
    /* consume word chars */
    while (end < state->input_length && !isspace((unsigned char)state->input[end])) {
        end++;
    }
    memmove(
        state->input + state->cursor,
        state->input + end,
        state->input_length - end + 1u
    );
    state->input_length -= end - state->cursor;
}

/* Readline Alt-B: move cursor one word to the left. */
static void psi_tui_move_word_backward(struct psi_tui_state *state) {
    size_t pos;
    if (state == NULL || state->input == NULL || state->cursor == 0u) return;
    pos = state->cursor;
    while (pos > 0u && isspace((unsigned char)state->input[pos - 1u])) pos--;
    while (pos > 0u && !isspace((unsigned char)state->input[pos - 1u])) pos--;
    state->cursor = pos;
}

/* Readline Alt-F: move cursor one word to the right. */
static void psi_tui_move_word_forward(struct psi_tui_state *state) {
    size_t pos;
    if (state == NULL || state->input == NULL) return;
    pos = state->cursor;
    while (pos < state->input_length && isspace((unsigned char)state->input[pos])) pos++;
    while (pos < state->input_length && !isspace((unsigned char)state->input[pos])) pos++;
    state->cursor = pos;
}

/* Readline Ctrl-K: kill from cursor to end of line. */
static void psi_tui_kill_to_end(struct psi_tui_state *state) {
    if (state == NULL || state->input == NULL) return;
    state->input[state->cursor] = '\0';
    state->input_length = state->cursor;
}

/* Readline Ctrl-U: kill from start to cursor. */
static void psi_tui_kill_to_start(struct psi_tui_state *state) {
    if (state == NULL || state->input == NULL || state->cursor == 0u) return;
    memmove(state->input, state->input + state->cursor,
            state->input_length - state->cursor + 1u);
    state->input_length -= state->cursor;
    state->cursor = 0u;
}

static int psi_tui_init_colors(void) {
    if (!has_colors()) {
        return PSI_STATUS_ERROR;
    }
    start_color();
    use_default_colors();
    init_pair(1, COLOR_BLUE, -1);
    init_pair(2, COLOR_CYAN, -1);
    init_pair(3, COLOR_WHITE, -1);
    init_pair(4, COLOR_YELLOW, -1);
    init_pair(5, COLOR_GREEN, -1);
    init_pair(6, COLOR_RED, -1);
    init_pair(7, -1, -1); /* info: default foreground for portability across light/dark terminals */
    return PSI_STATUS_OK;
}

static int psi_tui_setup_runtime(struct psi_tui_state *state, const struct psi_cli_options *options) {
    int status;

    status = psi_agent_runtime_init(&state->runtime, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }
    psi_agent_runtime_configure(&state->runtime, options->model, options->max_tokens);
    if (options->session_file != NULL) {
        if (psi_agent_runtime_load_session(&state->runtime, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_agent_runtime_free(&state->runtime);
            return PSI_STATUS_ERROR;
        }
    }
    return PSI_STATUS_OK;
}

static int psi_tui_state_init(struct psi_tui_state *state, const struct psi_cli_options *options) {
    memset(state, 0, sizeof(*state));
    state->options = options;
    state->streaming_assistant_index = -1;
    state->streaming_thinking_index = -1;
    state->running = 1;
    psi_abort_signal_init(&state->abort_signal);
    return PSI_STATUS_OK;
}

static void psi_tui_state_free(struct psi_tui_state *state) {
    size_t index;
    if (state == NULL) return;
    for (index = 0u; index < state->entry_count; index++) {
        psi_tui_free_entry(&state->entries[index]);
    }
    free(state->entries);
    free(state->input);
    free(state->status_text);
    psi_agent_runtime_free(&state->runtime);
}

int psi_run_tui_mode(const struct psi_cli_options *options) {
    struct psi_tui_state state;
    int ch;
    int status;

    if (!isatty(fileno(stdin)) || !isatty(fileno(stdout))) {
        fprintf(stderr, "TUI mode requires a terminal\n");
        return PSI_STATUS_ERROR;
    }

    if (psi_tui_state_init(&state, options) != PSI_STATUS_OK) {
        fprintf(stderr, "TUI state init failed\n");
        return PSI_STATUS_ERROR;
    }
    if (psi_tui_reserve_input(&state, 1u) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    state.input[0] = '\0';

    if (psi_tui_setup_runtime(&state, options) != PSI_STATUS_OK) {
        psi_tui_state_free(&state);
        return PSI_STATUS_ERROR;
    }
    psi_tui_rebuild_from_session(&state);

    setlocale(LC_ALL, "");
    initscr();
    raw();
    nonl();
    noecho();
    keypad(stdscr, TRUE);
    /* Leave the mouse to the terminal so click-drag text selection and
     * clipboard copy work. Users scroll the transcript with PgUp/PgDn
     * or the arrow keys. */
    scrollok(stdscr, FALSE);
    set_escdelay(25);
    psi_tui_init_colors();
    psi_tui_redraw(&state);

    status = PSI_STATUS_OK;
    while (state.running) {
        /* No worker thread — the main loop is idle between turns.
         * Block indefinitely on getch; a submit kicks off
         * psi_tui_run_turn_sync which drives the coroutine to
         * completion with the tick hook keeping the UI alive. */
        wtimeout(stdscr, -1);
        ch = getch();
        if (ch == ERR) continue;

        if (ch == KEY_RESIZE) { clearok(stdscr, TRUE); psi_tui_redraw(&state); continue; }
        if (ch == KEY_PPAGE)  { psi_tui_scroll_by(&state, state.height > 8 ? state.height / 2 : 4); psi_tui_redraw(&state); continue; }
        if (ch == KEY_NPAGE)  { psi_tui_scroll_by(&state, -(state.height > 8 ? state.height / 2 : 4)); psi_tui_redraw(&state); continue; }
        if (ch == KEY_UP)     { psi_tui_scroll_by(&state, 1); psi_tui_redraw(&state); continue; }
        if (ch == KEY_DOWN)   { psi_tui_scroll_by(&state, -1); psi_tui_redraw(&state); continue; }

        /* Esc: peek for Alt-<key> readline binding (b/f/d/Backspace).
         * A bare Esc in idle mode is a no-op. */
        if (ch == 27) {
            int next;
            wtimeout(stdscr, 25);
            next = getch();
            wtimeout(stdscr, -1);
            if (next == ERR) continue;
            switch (next) {
                case 'b': case 'B':
                    psi_tui_move_word_backward(&state);
                    break;
                case 'f': case 'F':
                    psi_tui_move_word_forward(&state);
                    break;
                case 'd': case 'D':
                    psi_tui_delete_word_forward(&state);
                    break;
                case KEY_BACKSPACE: case 127: case 8:
                    psi_tui_delete_word_backward(&state);
                    break;
                default:
                    break;
            }
            psi_tui_redraw(&state);
            continue;
        }

        /* Readline-style control keys:
         *   ^A home  ^B left  ^D delete-forward / EOF-exit
         *   ^E end   ^F right ^H backspace
         *   ^K kill-to-end  ^L redraw
         *   ^U kill-to-start ^W delete-word-backward
         *   ^Z suspend */
        if (ch == 4 && state.input_length == 0u) {
            state.running = 0;
            continue;
        } else if (ch == 4) {
            psi_tui_delete_forward(&state);
        } else if (ch == 26) {
            /* Ctrl-Z: suspend. Leave ncurses mode, raise SIGTSTP with
             * the default handler so the shell gets control, then
             * re-enter ncurses when we resume. */
            endwin();
            {
                struct sigaction dfl, prev;
                sigset_t mask, prev_mask;
                dfl.sa_handler = SIG_DFL;
                sigemptyset(&dfl.sa_mask);
                dfl.sa_flags = 0;
                sigaction(SIGTSTP, &dfl, &prev);
                sigemptyset(&mask);
                sigaddset(&mask, SIGTSTP);
                sigprocmask(SIG_UNBLOCK, &mask, &prev_mask);
                raise(SIGTSTP);
                sigprocmask(SIG_SETMASK, &prev_mask, NULL);
                sigaction(SIGTSTP, &prev, NULL);
            }
            refresh();
            clearok(stdscr, TRUE);
            psi_tui_redraw(&state);
            continue;
        } else if (ch == 11) {
            psi_tui_kill_to_end(&state);
        } else if (ch == 12) {
            clearok(stdscr, TRUE);
        } else if (ch == 21) {
            psi_tui_kill_to_start(&state);
        } else if (ch == 23) {
            psi_tui_delete_word_backward(&state);
        } else if (ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
            psi_tui_delete_backward(&state);
        } else if (ch == KEY_LEFT || ch == 2) {
            if (state.cursor > 0u) state.cursor--;
        } else if (ch == KEY_RIGHT || ch == 6) {
            if (state.cursor < state.input_length) state.cursor++;
        } else if (ch == KEY_HOME || ch == 1) {
            state.cursor = 0u;
        } else if (ch == KEY_END || ch == 5) {
            state.cursor = state.input_length;
        } else if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            (void)psi_tui_submit(&state);
        } else if (isprint(ch)) {
            psi_tui_insert_char(&state, ch);
        }

        psi_tui_redraw(&state);
    }

    endwin();
    psi_tui_state_free(&state);
    return status;
}
