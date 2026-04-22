#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <pthread.h>
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
};

struct psi_tui_render_line {
    char *text;
    int color_pair;
    int attrs;
};

enum psi_tui_event_kind {
    PSI_TUI_EVENT_TEXT_DELTA = 0,
    PSI_TUI_EVENT_TOOL_CALL = 1,
    PSI_TUI_EVENT_TOOL_RESULT = 2,
    PSI_TUI_EVENT_TOOL_PROGRESS = 3,
    PSI_TUI_EVENT_THINKING_DELTA = 4,
    PSI_TUI_EVENT_TURN_DONE = 5,
    PSI_TUI_EVENT_COMPACT_DONE = 6
};

struct psi_tui_event {
    enum psi_tui_event_kind kind;
    char *text;         /* pre-rendered display text (delta / tool summary) */
    char *tool_name;    /* tool call / tool result */
    int is_error;       /* tool result */
    int worker_status;  /* turn/compact done status */
    char *turn_response;/* turn done: response text (owned) */
    char *compact_summary; /* compact done: summary text (owned) */
    int save_failed;    /* turn/compact done: session save status */
    struct psi_tui_event *next;
};

enum psi_tui_task_kind {
    PSI_TUI_TASK_NONE = 0,
    PSI_TUI_TASK_TURN = 1,
    PSI_TUI_TASK_COMPACT = 2
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
    int width;
    int height;

    /* Background-worker plumbing. Observer callbacks run on worker_thread
     * and push pre-rendered events onto the queue under event_lock. The
     * main loop drains the queue between getch() ticks. */
    pthread_t worker_thread;
    int worker_thread_valid;
    enum psi_tui_task_kind worker_task;
    pthread_mutex_t event_lock;
    struct psi_tui_event *event_head;
    struct psi_tui_event *event_tail;
    char *turn_line;
    long compact_keep_recent;
    /* Index of the live tool-output entry receiving streaming progress
     * chunks, or -1 when no tool is currently streaming. Main thread only. */
    int streaming_tool_index;
    int streaming_thinking_index;
    /* Cancellation token shared with the worker. Main thread triggers it
     * when the user presses Esc; the worker polls it inside curl transfer
     * hooks and psi_process_run_shell. */
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
static void psi_tui_kill_to_end(struct psi_tui_state *state);
static void psi_tui_kill_to_start(struct psi_tui_state *state);
static void psi_tui_free_event(struct psi_tui_event *event);
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
    entry->title = NULL;
    entry->text = NULL;
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
    if (entry->title == NULL || entry->text == NULL) {
        psi_tui_free_entry(entry);
        return -1;
    }

    state->entry_count++;
    return (int)(state->entry_count - 1u);
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

    if (entry->kind == PSI_TUI_ENTRY_TOOL_RESULT || entry->kind == PSI_TUI_ENTRY_COMPACTION) {
        if (psi_tui_line_has_prefix(line_text, "+ ")) {
            *color_pair = 5;
            *attrs = A_BOLD;
        } else if (psi_tui_line_has_prefix(line_text, "- ")) {
            *color_pair = 6;
            *attrs = A_BOLD;
        } else if (psi_tui_line_has_prefix(line_text, "  ")) {
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

    cursor = text != NULL ? text : "";
    prefix = prefix_first != NULL ? prefix_first : "";
    while (1) {
        line_start = cursor;
        line_end = strchr(line_start, '\n');
        if (line_end == NULL) {
            line_end = line_start + strlen(line_start);
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
    switch (entry->kind) {
        case PSI_TUI_ENTRY_USER:
            *prefix_first = "You: ";
            *prefix_rest = "     ";
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
            *prefix_first = "  ";
            *prefix_rest = "  ";
            *color_pair = 4;
            *attrs = 0;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_TOOL_RESULT:
            *prefix_first = "  ";
            *prefix_rest = "  ";
            *color_pair = entry->is_error ? 6 : 5;
            *attrs = 0;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_ERROR:
            *prefix_first = "[error] ";
            *prefix_rest = "        ";
            *color_pair = 6;
            *attrs = A_BOLD;
            return PSI_STATUS_OK;
        case PSI_TUI_ENTRY_COMPACTION:
            *prefix_first = "[compact] ";
            *prefix_rest = "          ";
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
            *prefix_first = "[info] ";
            *prefix_rest = "       ";
            *color_pair = 7;
            *attrs = 0;
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
        if (count > 0u && psi_tui_render_add_line(&lines, &count, &capacity, "", 0, 0) != PSI_STATUS_OK) {
            psi_tui_render_free_lines(lines, count);
            return PSI_STATUS_ERROR;
        }

        psi_tui_entry_style(&state->entries[index], &prefix_first, &prefix_rest, &color_pair, &attrs);
        if (psi_tui_render_wrapped(
                &lines,
                &count,
                &capacity,
                &state->entries[index],
                prefix_first,
                prefix_rest,
                state->entries[index].text,
                color_pair,
                attrs,
                state->width
            ) != PSI_STATUS_OK) {
            psi_tui_render_free_lines(lines, count);
            return PSI_STATUS_ERROR;
        }
    }

    *lines_out = lines;
    *count_out = count;
    return PSI_STATUS_OK;
}

static void psi_tui_footer_lines(
    struct psi_tui_state *state,
    char *line1,
    size_t line1_size,
    char *line2,
    size_t line2_size
) {
    char cwd_buffer[4096];
    char model_buffer[256];
    char scroll_buffer[64];
    const char *cwd;

    cwd = getcwd(cwd_buffer, sizeof(cwd_buffer));
    if (cwd == NULL) {
        snprintf(cwd_buffer, sizeof(cwd_buffer), "<cwd unavailable: %s>", strerror(errno));
    }

    snprintf(
        line1,
        line1_size,
        "%s",
        cwd_buffer
    );

    if (state->scroll_offset > 0) {
        snprintf(scroll_buffer, sizeof(scroll_buffer), " scroll:%d", state->scroll_offset);
    } else {
        scroll_buffer[0] = '\0';
    }
    snprintf(model_buffer, sizeof(model_buffer), "%s", state->runtime.model != NULL ? state->runtime.model : "claude-opus-4-7");
    snprintf(
        line2,
        line2_size,
        "model:%s  messages:%lu%s%s",
        model_buffer,
        (unsigned long)state->runtime.session.count,
        state->busy ? "  working" : "",
        scroll_buffer
    );
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
    char footer_line1[4096];
    char footer_line2[512];
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
                psi_tui_draw_line(
                    transcript_start + (int)index,
                    lines[source_index].text,
                    lines[source_index].color_pair,
                    lines[source_index].attrs
                );
            } else {
                psi_tui_draw_line(transcript_start + (int)index, "", 0, 0);
            }
        }
    }
    psi_tui_render_free_lines(lines, line_count);

    psi_tui_draw_line(
        status_row,
        state->status_text != NULL ? state->status_text :
            (state->busy ? "Working... Up/Down, PageUp/PageDown, or mouse wheel scroll" :
                "Enter to submit, Up/Down or PageUp/PageDown to scroll, Ctrl+D or /quit to exit"),
        state->status_is_error ? 6 : 7,
        state->status_is_error ? A_BOLD : A_DIM
    );

    psi_tui_footer_lines(state, footer_line1, sizeof(footer_line1), footer_line2, sizeof(footer_line2));
    psi_tui_draw_line(footer_row1, footer_line1, 7, A_DIM);
    psi_tui_draw_line(footer_row2, footer_line2, 7, A_DIM);

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

/* Count the total rendered line count for the current transcript. Used to
 * preserve scroll anchoring while new content streams in: if the user has
 * scrolled up (scroll_offset > 0), we add the growth delta back to keep
 * their view locked to the same content instead of drifting toward the
 * bottom as lines pile on. Returns 0 on allocation failure. */
static size_t psi_tui_total_rendered_lines(struct psi_tui_state *state) {
    struct psi_tui_render_line *lines;
    size_t line_count;

    if (state == NULL) {
        return 0u;
    }
    lines = NULL;
    line_count = 0u;
    if (psi_tui_build_render_lines(state, &lines, &line_count) != PSI_STATUS_OK) {
        return 0u;
    }
    psi_tui_render_free_lines(lines, line_count);
    return line_count;
}

/* Push an event onto the thread-safe queue. Takes ownership of any heap
 * strings passed via the event struct. */
static void psi_tui_push_event(struct psi_tui_state *state, struct psi_tui_event *event) {
    if (state == NULL || event == NULL) {
        if (event != NULL) {
            free(event->text);
            free(event->tool_name);
            free(event->turn_response);
            free(event);
        }
        return;
    }
    event->next = NULL;
    pthread_mutex_lock(&state->event_lock);
    if (state->event_tail == NULL) {
        state->event_head = event;
    } else {
        state->event_tail->next = event;
    }
    state->event_tail = event;
    pthread_mutex_unlock(&state->event_lock);
}

static struct psi_tui_event *psi_tui_pop_event(struct psi_tui_state *state) {
    struct psi_tui_event *event;

    if (state == NULL) {
        return NULL;
    }
    pthread_mutex_lock(&state->event_lock);
    event = state->event_head;
    if (event != NULL) {
        state->event_head = event->next;
        if (state->event_head == NULL) {
            state->event_tail = NULL;
        }
    }
    pthread_mutex_unlock(&state->event_lock);
    if (event != NULL) {
        event->next = NULL;
    }
    return event;
}

static struct psi_tui_event *psi_tui_event_new(enum psi_tui_event_kind kind) {
    struct psi_tui_event *event;

    event = (struct psi_tui_event *)calloc(1u, sizeof(*event));
    if (event == NULL) {
        return NULL;
    }
    event->kind = kind;
    return event;
}

/* Observer callbacks run on the worker thread. They pre-render via Lua
 * (safe since only the worker touches Lua during a turn) and push
 * plain-string events to the queue. The main thread owns all curses and
 * transcript mutations. */
static void psi_tui_observer_text_delta(void *userdata, const char *text) {
    struct psi_tui_state *state;
    struct psi_tui_event *event;

    state = (struct psi_tui_state *)userdata;
    if (state == NULL || text == NULL) {
        return;
    }
    event = psi_tui_event_new(PSI_TUI_EVENT_TEXT_DELTA);
    if (event == NULL) {
        return;
    }
    event->text = psi_strdup(text);
    if (event->text == NULL) {
        free(event);
        return;
    }
    psi_tui_push_event(state, event);
}

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

static void psi_tui_observer_tool_call(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json) {
    struct psi_tui_state *state;
    char *summary;
    struct psi_tui_event *event;

    state = (struct psi_tui_state *)userdata;
    if (state == NULL || tool_name == NULL) {
        return;
    }
    /* psi_tui_render_tool_call_text invokes Lua and reads state; safe on
     * worker because only worker touches Lua during the turn. We only
     * read state here, never mutate it. */
    summary = psi_tui_render_tool_call_text(state, tool_call_id, tool_name, input_json);
    event = psi_tui_event_new(PSI_TUI_EVENT_TOOL_CALL);
    if (event == NULL) {
        free(summary);
        return;
    }
    event->text = summary;
    event->tool_name = psi_strdup(tool_name);
    if (event->tool_name == NULL) {
        free(event->text);
        free(event);
        return;
    }
    psi_tui_push_event(state, event);
}

static void psi_tui_observer_thinking_delta(void *userdata, const char *text) {
    struct psi_tui_state *state;
    struct psi_tui_event *event;

    state = (struct psi_tui_state *)userdata;
    if (state == NULL || text == NULL || text[0] == '\0') {
        return;
    }
    event = psi_tui_event_new(PSI_TUI_EVENT_THINKING_DELTA);
    if (event == NULL) {
        return;
    }
    event->text = psi_strdup(text);
    if (event->text == NULL) {
        free(event);
        return;
    }
    psi_tui_push_event(state, event);
}

static void psi_tui_observer_tool_progress(void *userdata, const char *tool_call_id, const char *chunk, size_t len) {
    struct psi_tui_state *state;
    struct psi_tui_event *event;
    char *copy;

    PSI_UNUSED(tool_call_id);
    state = (struct psi_tui_state *)userdata;
    if (state == NULL || chunk == NULL || len == 0u) {
        return;
    }
    copy = (char *)malloc(len + 1u);
    if (copy == NULL) {
        return;
    }
    memcpy(copy, chunk, len);
    copy[len] = '\0';

    event = psi_tui_event_new(PSI_TUI_EVENT_TOOL_PROGRESS);
    if (event == NULL) {
        free(copy);
        return;
    }
    event->text = copy;
    psi_tui_push_event(state, event);
}

static void psi_tui_observer_tool_result(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json) {
    struct psi_tui_state *state;
    char *summary;
    int is_error;
    struct psi_tui_event *event;

    state = (struct psi_tui_state *)userdata;
    if (state == NULL || tool_name == NULL) {
        return;
    }
    summary = psi_tui_render_tool_result_text(state, tool_call_id, tool_name, output_json, &is_error);
    event = psi_tui_event_new(PSI_TUI_EVENT_TOOL_RESULT);
    if (event == NULL) {
        free(summary);
        return;
    }
    event->text = summary;
    event->tool_name = psi_strdup(tool_name);
    event->is_error = is_error;
    if (event->tool_name == NULL) {
        free(event->text);
        free(event);
        return;
    }
    psi_tui_push_event(state, event);
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

/* Worker thread: runs whichever task was queued (turn or compact).
 * Observer callbacks push events during a turn. After the operation
 * completes (and the session is saved), push a TURN_DONE or
 * COMPACT_DONE event. Main thread drains events, joins the worker,
 * and clears busy state. */
static void *psi_tui_run_turn(struct psi_tui_state *state) {
    struct psi_agent_observer observer;
    struct psi_tui_stdio_guard stdio_guard;
    char *response_text;
    int status;
    int save_failed;
    struct psi_tui_event *done_event;

    memset(&observer, 0, sizeof(observer));
    observer.userdata = state;
    observer.on_assistant_text_delta = psi_tui_observer_text_delta;
    observer.on_tool_call = psi_tui_observer_tool_call;
    observer.on_tool_result = psi_tui_observer_tool_result;
    observer.on_tool_progress = psi_tui_observer_tool_progress;
    observer.on_thinking_delta = psi_tui_observer_thinking_delta;

    response_text = NULL;
    save_failed = 0;
    stdio_guard.active = 0;
    status = psi_tui_stdio_guard_begin(&stdio_guard);
    if (status == PSI_STATUS_OK) {
        status = psi_agent_runtime_turn_with_observer(
            &state->runtime, state->turn_line, &observer,
            &state->abort_signal, &response_text);
        if (status == PSI_STATUS_OK) {
            if (psi_agent_runtime_save(&state->runtime) != PSI_STATUS_OK) {
                save_failed = 1;
            }
        }
        psi_tui_stdio_guard_end(&stdio_guard);
    }

    done_event = psi_tui_event_new(PSI_TUI_EVENT_TURN_DONE);
    if (done_event != NULL) {
        done_event->worker_status = status;
        done_event->save_failed = save_failed;
        done_event->turn_response = response_text;
        psi_tui_push_event(state, done_event);
    } else {
        free(response_text);
    }
    return NULL;
}

static void *psi_tui_run_compact(struct psi_tui_state *state) {
    struct psi_tui_stdio_guard stdio_guard;
    char *summary;
    int status;
    int save_failed;
    struct psi_tui_event *done_event;

    summary = NULL;
    save_failed = 0;
    stdio_guard.active = 0;
    status = psi_tui_stdio_guard_begin(&stdio_guard);
    if (status == PSI_STATUS_OK) {
        status = psi_agent_runtime_compact(
            &state->runtime, (size_t)state->compact_keep_recent,
            &state->abort_signal, &summary);
        if (status == PSI_STATUS_OK) {
            if (psi_agent_runtime_save(&state->runtime) != PSI_STATUS_OK) {
                save_failed = 1;
            }
        }
        psi_tui_stdio_guard_end(&stdio_guard);
    }

    done_event = psi_tui_event_new(PSI_TUI_EVENT_COMPACT_DONE);
    if (done_event != NULL) {
        done_event->worker_status = status;
        done_event->save_failed = save_failed;
        done_event->compact_summary = summary;
        psi_tui_push_event(state, done_event);
    } else {
        free(summary);
    }
    return NULL;
}

static void *psi_tui_worker_main(void *arg) {
    struct psi_tui_state *state = (struct psi_tui_state *)arg;
    switch (state->worker_task) {
        case PSI_TUI_TASK_TURN:    return psi_tui_run_turn(state);
        case PSI_TUI_TASK_COMPACT: return psi_tui_run_compact(state);
        case PSI_TUI_TASK_NONE:
        default:                   return NULL;
    }
}

static int psi_tui_submit(struct psi_tui_state *state) {
    char *line;
    int status;

    if (state == NULL || state->busy || state->input_length == 0u) {
        return PSI_STATUS_OK;
    }

    line = psi_strdup(state->input);
    if (line == NULL) {
        return PSI_STATUS_ERROR;
    }

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
    psi_tui_set_status(state, "Working...", 0);
    psi_tui_redraw(state);

    free(state->turn_line);
    state->turn_line = line;
    state->worker_task = PSI_TUI_TASK_TURN;
    psi_abort_signal_reset(&state->abort_signal);
    if (pthread_create(&state->worker_thread, NULL, psi_tui_worker_main, state) != 0) {
        state->busy = 0;
        state->worker_task = PSI_TUI_TASK_NONE;
        state->streaming_assistant_index = -1;
        psi_tui_set_status(state, "failed to spawn worker", 1);
        free(state->turn_line);
        state->turn_line = NULL;
        psi_tui_redraw(state);
        return PSI_STATUS_ERROR;
    }
    state->worker_thread_valid = 1;
    return PSI_STATUS_OK;
}

static int psi_tui_start_compact(struct psi_tui_state *state, long keep_recent) {
    if (state == NULL || state->busy) {
        return PSI_STATUS_OK;
    }
    state->busy = 1;
    state->compact_keep_recent = keep_recent;
    state->worker_task = PSI_TUI_TASK_COMPACT;
    psi_abort_signal_reset(&state->abort_signal);
    psi_tui_set_status(state, "Compacting...", 0);
    psi_tui_redraw(state);
    if (pthread_create(&state->worker_thread, NULL, psi_tui_worker_main, state) != 0) {
        state->busy = 0;
        state->worker_task = PSI_TUI_TASK_NONE;
        psi_tui_set_status(state, "failed to spawn worker", 1);
        psi_tui_redraw(state);
        return PSI_STATUS_ERROR;
    }
    state->worker_thread_valid = 1;
    return PSI_STATUS_OK;
}

/* Drain pending render events. Called from the main loop between getch
 * ticks while a turn is in flight. */
static void psi_tui_drain_events(struct psi_tui_state *state) {
    struct psi_tui_event *event;
    int dirty;
    int was_scrolled_up;
    size_t lines_before;
    size_t lines_after;

    if (state == NULL) {
        return;
    }

    /* Snapshot scroll state before touching entries. If the user has
     * scrolled up to read earlier content, we want their view to stay
     * anchored there as new deltas land. scroll_offset counts lines above
     * the visible bottom, so growth of the transcript must be added back
     * in to compensate; otherwise their view drifts toward the live tail. */
    was_scrolled_up = state->scroll_offset > 0;
    lines_before = was_scrolled_up ? psi_tui_total_rendered_lines(state) : 0u;

    dirty = 0;
    while ((event = psi_tui_pop_event(state)) != NULL) {
        switch (event->kind) {
            case PSI_TUI_EVENT_TEXT_DELTA:
                state->streaming_thinking_index = -1;
                if (state->streaming_assistant_index < 0) {
                    state->streaming_assistant_index =
                        psi_tui_add_entry(state, PSI_TUI_ENTRY_ASSISTANT, NULL, "", 0);
                }
                psi_tui_append_entry_text(state, state->streaming_assistant_index,
                                          event->text != NULL ? event->text : "");
                break;
            case PSI_TUI_EVENT_THINKING_DELTA:
                if (state->streaming_thinking_index < 0) {
                    state->streaming_thinking_index =
                        psi_tui_add_entry(state, PSI_TUI_ENTRY_THINKING, NULL, "", 0);
                }
                psi_tui_append_entry_text(state, state->streaming_thinking_index,
                                          event->text != NULL ? event->text : "");
                break;
            case PSI_TUI_EVENT_TOOL_CALL:
                psi_tui_finish_streaming_assistant(state);
                state->streaming_thinking_index = -1;
                state->streaming_tool_index = -1;
                psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_CALL,
                                  event->tool_name, event->text, 0);
                break;
            case PSI_TUI_EVENT_TOOL_PROGRESS:
                if (state->streaming_tool_index < 0) {
                    state->streaming_tool_index =
                        psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT, NULL, "", 0);
                }
                psi_tui_append_entry_text(state, state->streaming_tool_index,
                                          event->text != NULL ? event->text : "");
                break;
            case PSI_TUI_EVENT_TOOL_RESULT:
                /* If we streamed progress for this call, replace the live
                 * entry with the final formatted render. Otherwise add a
                 * fresh result entry. */
                if (state->streaming_tool_index >= 0 &&
                    (size_t)state->streaming_tool_index < state->entry_count) {
                    struct psi_tui_entry *entry = &state->entries[state->streaming_tool_index];
                    free(entry->title);
                    free(entry->text);
                    entry->title = event->tool_name != NULL ? psi_strdup(event->tool_name) : NULL;
                    entry->text = event->text != NULL ? psi_strdup(event->text) : psi_strdup("");
                    entry->is_error = event->is_error;
                } else {
                    psi_tui_add_entry(state, PSI_TUI_ENTRY_TOOL_RESULT,
                                      event->tool_name, event->text, event->is_error);
                }
                state->streaming_tool_index = -1;
                break;
            case PSI_TUI_EVENT_TURN_DONE:
                if (state->worker_thread_valid) {
                    pthread_join(state->worker_thread, NULL);
                    state->worker_thread_valid = 0;
                }
                if (event->worker_status != PSI_STATUS_OK) {
                    psi_tui_set_status(state, "agent turn failed", 1);
                    psi_tui_finish_streaming_assistant(state);
                    psi_tui_add_entry(state, PSI_TUI_ENTRY_ERROR, NULL, "Anthropic request failed", 1);
                } else if (event->save_failed) {
                    psi_tui_finish_streaming_assistant(state);
                    psi_tui_set_status(state, "failed to save session file", 1);
                } else {
                    psi_tui_finish_streaming_assistant(state);
                    psi_tui_set_status(state, "", 0);
                }
                state->streaming_assistant_index = -1;
                state->streaming_thinking_index = -1;
                state->streaming_tool_index = -1;
                state->worker_task = PSI_TUI_TASK_NONE;
                state->busy = 0;
                free(state->turn_line);
                state->turn_line = NULL;
                break;
            case PSI_TUI_EVENT_COMPACT_DONE:
                if (state->worker_thread_valid) {
                    pthread_join(state->worker_thread, NULL);
                    state->worker_thread_valid = 0;
                }
                if (event->worker_status != PSI_STATUS_OK) {
                    psi_tui_set_status(state, "failed to compact session", 1);
                } else {
                    psi_tui_rebuild_from_session(state);
                    if (event->save_failed) {
                        psi_tui_set_status(state, "failed to save compacted session", 1);
                    } else {
                        psi_tui_set_status(state, "session compacted", 0);
                    }
                }
                state->worker_task = PSI_TUI_TASK_NONE;
                state->busy = 0;
                break;
        }
        psi_tui_free_event(event);
        dirty = 1;
    }
    if (dirty) {
        if (was_scrolled_up && state->scroll_offset > 0) {
            lines_after = psi_tui_total_rendered_lines(state);
            if (lines_after > lines_before) {
                state->scroll_offset += (int)(lines_after - lines_before);
            }
        }
        psi_tui_redraw(state);
    }
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
    state->streaming_tool_index = -1;
    state->streaming_thinking_index = -1;
    state->running = 1;
    psi_abort_signal_init(&state->abort_signal);
    if (pthread_mutex_init(&state->event_lock, NULL) != 0) {
        return PSI_STATUS_ERROR;
    }
    return PSI_STATUS_OK;
}

static void psi_tui_free_event(struct psi_tui_event *event) {
    if (event == NULL) {
        return;
    }
    free(event->text);
    free(event->tool_name);
    free(event->turn_response);
    free(event);
}

/* gcc -fanalyzer sometimes clones this function (`.part.0`) for the
 * non-null path and loses the NULL guard below, reporting a false
 * dereference on the loop. The check IS present — silence only this
 * analyzer warning so -fanalyzer builds stay clean. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wanalyzer-null-dereference"
static void psi_tui_state_free(struct psi_tui_state *state) {
    size_t index;
    struct psi_tui_event *event;

    if (state == NULL) {
        return;
    }
    /* Drain any remaining events. */
    while ((event = psi_tui_pop_event(state)) != NULL) {
        psi_tui_free_event(event);
    }
    pthread_mutex_destroy(&state->event_lock);
    for (index = 0u; index < state->entry_count; index++) {
        psi_tui_free_entry(&state->entries[index]);
    }
    free(state->entries);
    free(state->input);
    free(state->status_text);
    free(state->turn_line);
    psi_agent_runtime_free(&state->runtime);
}
#pragma GCC diagnostic pop

int psi_run_tui_mode(const struct psi_cli_options *options) {
    struct psi_tui_state state;
    int ch;
    int status;

    if (!isatty(fileno(stdin)) || !isatty(fileno(stdout))) {
        fprintf(stderr, "TUI mode requires a terminal\n");
        return PSI_STATUS_ERROR;
    }

    if (psi_tui_state_init(&state, options) != PSI_STATUS_OK) {
        fprintf(stderr, "TUI state init failed (mutex)\n");
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
        /* Poll with a short timeout while busy so we can drain events from
         * the worker thread. Block indefinitely otherwise. */
        wtimeout(stdscr, state.busy ? 30 : -1);
        psi_tui_drain_events(&state);
        ch = getch();
        if (ch == ERR) {
            continue;
        }

        if (ch == KEY_RESIZE) {
            psi_tui_redraw(&state);
            continue;
        }
        if (ch == KEY_PPAGE) {
            psi_tui_scroll_by(&state, state.height > 8 ? state.height / 2 : 4);
            psi_tui_redraw(&state);
            continue;
        }
        if (ch == KEY_NPAGE) {
            psi_tui_scroll_by(&state, -(state.height > 8 ? state.height / 2 : 4));
            psi_tui_redraw(&state);
            continue;
        }
        if (ch == KEY_UP) {
            psi_tui_scroll_by(&state, 1);
            psi_tui_redraw(&state);
            continue;
        }
        if (ch == KEY_DOWN) {
            psi_tui_scroll_by(&state, -1);
            psi_tui_redraw(&state);
            continue;
        }

        /* Esc while busy: trigger the abort signal. Worker stops its
         * curl transfer, kills any child process, and pushes TURN_DONE /
         * COMPACT_DONE so the UI unblocks. Esc when idle: no-op. */
        if (ch == 27) {
            if (state.busy) {
                psi_abort_signal_trigger(&state.abort_signal);
                psi_tui_set_status(&state, "aborting...", 0);
                psi_tui_redraw(&state);
            }
            continue;
        }

        /* Input editing: allowed even while busy so the user can compose
         * their next message. Enter and Ctrl-D-exit are disabled during a
         * turn so submits stay serialized. */
        /* Readline-style control keys. Codes are the legacy ASCII
         * control positions:
         *   ^A=1 home   ^B=2 left     ^D=4 delete-forward / EOF-exit
         *   ^E=5 end    ^F=6 right    ^H=8 backspace
         *   ^K=11 kill-to-end         ^L=12 redraw
         *   ^U=21 kill-to-start       ^W=23 delete-word-backward */
        if (ch == 4 && state.input_length == 0u) {
            if (!state.busy) {
                state.running = 0;
            }
            continue;
        } else if (ch == 4) {
            psi_tui_delete_forward(&state);
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
            if (state.cursor > 0u) {
                state.cursor--;
            }
        } else if (ch == KEY_RIGHT || ch == 6) {
            if (state.cursor < state.input_length) {
                state.cursor++;
            }
        } else if (ch == KEY_HOME || ch == 1) {
            state.cursor = 0u;
        } else if (ch == KEY_END || ch == 5) {
            state.cursor = state.input_length;
        } else if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            /* Submit failures are non-fatal — the user can keep typing. */
            if (!state.busy) (void)psi_tui_submit(&state);
        } else if (isprint(ch)) {
            psi_tui_insert_char(&state, ch);
        }

        psi_tui_redraw(&state);
    }

    /* If a turn is still in flight at shutdown, wait for it to finish so
     * the worker doesn't touch freed state. */
    if (state.worker_thread_valid) {
        pthread_join(state.worker_thread, NULL);
        state.worker_thread_valid = 0;
    }

    endwin();
    psi_tui_state_free(&state);
    return status;
}
