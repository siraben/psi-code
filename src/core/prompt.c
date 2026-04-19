#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <direct.h>
#define psi_getcwd _getcwd
#else
#include <unistd.h>
#define psi_getcwd getcwd
#endif
#include "psi/common.h"
#include "psi/prompt.h"
#include "psi/tool.h"

struct psi_prompt_buffer {
    char *data;
    size_t length;
    size_t capacity;
};

struct psi_context_file {
    char *path;
    char *content;
};

static const long PSI_PROMPT_CONTEXT_MAX_BYTES = 262144l;

static void psi_prompt_buffer_init(struct psi_prompt_buffer *buffer) {
    buffer->data = NULL;
    buffer->length = 0u;
    buffer->capacity = 0u;
}

static void psi_prompt_buffer_free(struct psi_prompt_buffer *buffer) {
    free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0u;
    buffer->capacity = 0u;
}

static int psi_prompt_buffer_reserve(struct psi_prompt_buffer *buffer, size_t extra) {
    size_t required;
    size_t next_capacity;
    char *next_data;

    required = buffer->length + extra + 1u;
    if (required <= buffer->capacity) {
        return PSI_STATUS_OK;
    }

    next_capacity = buffer->capacity == 0u ? 256u : buffer->capacity;
    while (next_capacity < required) {
        next_capacity *= 2u;
    }

    next_data = (char *)realloc(buffer->data, next_capacity);
    if (next_data == NULL) {
        return PSI_STATUS_ERROR;
    }

    buffer->data = next_data;
    buffer->capacity = next_capacity;
    return PSI_STATUS_OK;
}

static int psi_prompt_buffer_append_n(struct psi_prompt_buffer *buffer, const char *text, size_t length) {
    if (length == 0u) {
        return PSI_STATUS_OK;
    }

    if (psi_prompt_buffer_reserve(buffer, length) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    memcpy(buffer->data + buffer->length, text, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return PSI_STATUS_OK;
}

static int psi_prompt_buffer_append(struct psi_prompt_buffer *buffer, const char *text) {
    return psi_prompt_buffer_append_n(buffer, text, text ? strlen(text) : 0u);
}

static int psi_prompt_buffer_append_line(struct psi_prompt_buffer *buffer, const char *text) {
    if (psi_prompt_buffer_append(buffer, text) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    return psi_prompt_buffer_append(buffer, "\n");
}

static int psi_prompt_add_guideline(char **guidelines, size_t *count, const char *text) {
    char *copy;

    if (text == NULL) {
        return PSI_STATUS_OK;
    }

    copy = psi_strdup(text);
    if (copy == NULL) {
        return PSI_STATUS_ERROR;
    }

    guidelines[*count] = copy;
    *count += 1u;
    return PSI_STATUS_OK;
}

static void psi_prompt_free_guidelines(char **guidelines, size_t count) {
    size_t index;

    for (index = 0u; index < count; index++) {
        free(guidelines[index]);
    }
}

static int psi_prompt_read_file(const char *path, char **text_out) {
    FILE *file;
    long size;
    size_t read_size;
    char *buffer;

    *text_out = NULL;
    file = fopen(path, "rb");
    if (file == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_END) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    size = ftell(file);
    if (size < 0l || size > PSI_PROMPT_CONTEXT_MAX_BYTES) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    if (fseek(file, 0l, SEEK_SET) != 0) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    buffer = (char *)malloc((size_t)size + 1u);
    if (buffer == NULL) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    read_size = fread(buffer, 1u, (size_t)size, file);
    fclose(file);
    if (read_size != (size_t)size) {
        free(buffer);
        return PSI_STATUS_ERROR;
    }

    buffer[size] = '\0';
    *text_out = buffer;
    return PSI_STATUS_OK;
}

static char *psi_prompt_get_cwd(void) {
    size_t size;
    char *buffer;

    size = 256u;
    for (;;) {
        buffer = (char *)malloc(size);
        if (buffer == NULL) {
            return NULL;
        }

        if (psi_getcwd(buffer, (int)size) != NULL) {
            return buffer;
        }

        free(buffer);
        if (size >= 8192u) {
            break;
        }
        size *= 2u;
    }

    return psi_strdup(".");
}

static char *psi_prompt_parent_dir(const char *path) {
    char *copy;
    char *slash;

    copy = psi_strdup(path);
    if (copy == NULL) {
        return NULL;
    }

    slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return psi_strdup(".");
    }

    if (slash == copy) {
        slash[1] = '\0';
    } else {
        *slash = '\0';
    }

    return copy;
}

static int psi_prompt_collect_context_file(
    struct psi_context_file **files,
    size_t *count,
    const char *dir_path
) {
    static const char *candidates[] = { "AGENTS.md", "CLAUDE.md" };
    char path_buffer[4096];
    char *content;
    size_t index;
    struct psi_context_file *next_files;

    for (index = 0u; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
        sprintf(path_buffer, "%s%s%s", dir_path, strcmp(dir_path, "/") == 0 ? "" : "/", candidates[index]);
        content = NULL;
        if (psi_prompt_read_file(path_buffer, &content) == PSI_STATUS_OK) {
            next_files = (struct psi_context_file *)realloc(
                *files,
                (*count + 1u) * sizeof(struct psi_context_file)
            );
            if (next_files == NULL) {
                free(content);
                return PSI_STATUS_ERROR;
            }
            *files = next_files;
            (*files)[*count].path = psi_strdup(path_buffer);
            (*files)[*count].content = content;
            if ((*files)[*count].path == NULL) {
                free(content);
                (*files)[*count].content = NULL;
                return PSI_STATUS_ERROR;
            }
            *count += 1u;
            return PSI_STATUS_OK;
        }
    }

    return PSI_STATUS_OK;
}

static void psi_prompt_free_context_files(struct psi_context_file *files, size_t count) {
    size_t index;

    for (index = 0u; index < count; index++) {
        free(files[index].path);
        free(files[index].content);
    }
    free(files);
}

static int psi_prompt_load_context_files(struct psi_context_file **files, size_t *count, const char *cwd) {
    char **dirs;
    char *current;
    char *parent;
    size_t depth;
    size_t index;
    char **next_dirs;

    *files = NULL;
    *count = 0u;
    dirs = NULL;
    current = psi_strdup(cwd);
    if (current == NULL) {
        return PSI_STATUS_ERROR;
    }

    depth = 0u;
    for (;;) {
        next_dirs = (char **)realloc(dirs, (depth + 1u) * sizeof(char *));
        if (next_dirs == NULL) {
            free(current);
            for (index = 0u; index < depth; index++) {
                free(dirs[index]);
            }
            free(dirs);
            return PSI_STATUS_ERROR;
        }
        dirs = next_dirs;
        dirs[depth] = current;
        depth += 1u;

        parent = psi_prompt_parent_dir(current);
        if (parent == NULL) {
            for (index = 0u; index < depth; index++) {
                free(dirs[index]);
            }
            free(dirs);
            return PSI_STATUS_ERROR;
        }

        if (strcmp(parent, current) == 0) {
            free(parent);
            break;
        }
        current = parent;
    }

    for (index = depth; index > 0u; index--) {
        if (psi_prompt_collect_context_file(files, count, dirs[index - 1u]) != PSI_STATUS_OK) {
            for (depth = 0u; depth < index; depth++) {
                free(dirs[depth]);
            }
            free(dirs);
            psi_prompt_free_context_files(*files, *count);
            *files = NULL;
            *count = 0u;
            return PSI_STATUS_ERROR;
        }
    }

    for (index = 0u; index < depth; index++) {
        free(dirs[index]);
    }
    free(dirs);
    return PSI_STATUS_OK;
}

static int psi_prompt_append_date_and_cwd(struct psi_prompt_buffer *buffer, const char *cwd) {
    char date_buffer[32];
    time_t now_value;
    struct tm *local_time;

    now_value = time(NULL);
    local_time = localtime(&now_value);
    if (local_time == NULL) {
        return PSI_STATUS_ERROR;
    }

    sprintf(
        date_buffer,
        "%04d-%02d-%02d",
        local_time->tm_year + 1900,
        local_time->tm_mon + 1,
        local_time->tm_mday
    );

    if (psi_prompt_buffer_append(buffer, "\nCurrent date: ") != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    if (psi_prompt_buffer_append(buffer, date_buffer) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    if (psi_prompt_buffer_append(buffer, "\nCurrent working directory: ") != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }
    return psi_prompt_buffer_append(buffer, cwd);
}

int psi_build_system_prompt(char **output_text) {
    struct psi_prompt_buffer buffer;
    struct psi_context_file *context_files;
    const struct psi_tool_definition *tool_definitions;
    char *guidelines[16];
    size_t guideline_count;
    char *cwd;
    size_t index;
    size_t tool_count;
    size_t tool_index;
    size_t guideline_index;

    if (output_text == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    context_files = NULL;
    guideline_count = 0u;
    tool_definitions = psi_tool_definitions(&tool_count);
    cwd = psi_prompt_get_cwd();
    if (cwd == NULL) {
        return PSI_STATUS_ERROR;
    }

    psi_prompt_buffer_init(&buffer);
    if (psi_prompt_load_context_files(&context_files, &index, cwd) != PSI_STATUS_OK) {
        free(cwd);
        return PSI_STATUS_ERROR;
    }

    if (psi_prompt_buffer_append(
            &buffer,
            "You are an expert coding assistant operating inside psi, a coding agent harness. "
            "You help users by reading files, executing commands, editing code, and writing new files.\n\n"
            "Available tools:\n"
        ) != PSI_STATUS_OK) {
        free(cwd);
        psi_prompt_free_context_files(context_files, index);
        return PSI_STATUS_ERROR;
    }

    for (tool_index = 0u; tool_index < tool_count; tool_index++) {
        if (psi_prompt_buffer_append(&buffer, "- ") != PSI_STATUS_OK ||
            psi_prompt_buffer_append(&buffer, tool_definitions[tool_index].name) != PSI_STATUS_OK ||
            psi_prompt_buffer_append(&buffer, ": ") != PSI_STATUS_OK ||
            psi_prompt_buffer_append_line(&buffer, tool_definitions[tool_index].prompt_snippet) != PSI_STATUS_OK) {
            psi_prompt_buffer_free(&buffer);
            free(cwd);
            psi_prompt_free_context_files(context_files, index);
            return PSI_STATUS_ERROR;
        }
    }

    if (psi_prompt_add_guideline(&guidelines[0], &guideline_count, "Be concise in your responses.") != PSI_STATUS_OK ||
        psi_prompt_add_guideline(&guidelines[0], &guideline_count, "Show file paths clearly when working with files.") != PSI_STATUS_OK ||
        psi_prompt_add_guideline(&guidelines[0], &guideline_count, "Prefer minimal, targeted changes over broad rewrites.") != PSI_STATUS_OK) {
        psi_prompt_free_guidelines(&guidelines[0], guideline_count);
        psi_prompt_buffer_free(&buffer);
        free(cwd);
        psi_prompt_free_context_files(context_files, index);
        return PSI_STATUS_ERROR;
    }

    for (tool_index = 0u; tool_index < tool_count; tool_index++) {
        for (guideline_index = 0u; tool_definitions[tool_index].prompt_guidelines[guideline_index] != NULL; guideline_index++) {
            if (psi_prompt_add_guideline(
                    &guidelines[0],
                    &guideline_count,
                    tool_definitions[tool_index].prompt_guidelines[guideline_index]
                ) != PSI_STATUS_OK) {
                psi_prompt_free_guidelines(&guidelines[0], guideline_count);
                psi_prompt_buffer_free(&buffer);
                free(cwd);
                psi_prompt_free_context_files(context_files, index);
                return PSI_STATUS_ERROR;
            }
        }
    }

    if (psi_prompt_buffer_append(&buffer, "\nGuidelines:\n") != PSI_STATUS_OK) {
        psi_prompt_free_guidelines(&guidelines[0], guideline_count);
        psi_prompt_buffer_free(&buffer);
        free(cwd);
        psi_prompt_free_context_files(context_files, index);
        return PSI_STATUS_ERROR;
    }

    for (guideline_index = 0u; guideline_index < guideline_count; guideline_index++) {
        if (psi_prompt_buffer_append(&buffer, "- ") != PSI_STATUS_OK ||
            psi_prompt_buffer_append_line(&buffer, guidelines[guideline_index]) != PSI_STATUS_OK) {
            psi_prompt_free_guidelines(&guidelines[0], guideline_count);
            psi_prompt_buffer_free(&buffer);
            free(cwd);
            psi_prompt_free_context_files(context_files, index);
            return PSI_STATUS_ERROR;
        }
    }

    psi_prompt_free_guidelines(&guidelines[0], guideline_count);

    if (index > 0u) {
        if (psi_prompt_buffer_append(&buffer, "\n# Project Context\n\n") != PSI_STATUS_OK ||
            psi_prompt_buffer_append(&buffer, "Project-specific instructions and guidelines:\n\n") != PSI_STATUS_OK) {
            psi_prompt_buffer_free(&buffer);
            free(cwd);
            psi_prompt_free_context_files(context_files, index);
            return PSI_STATUS_ERROR;
        }

        for (tool_index = 0u; tool_index < index; tool_index++) {
            if (psi_prompt_buffer_append(&buffer, "## ") != PSI_STATUS_OK ||
                psi_prompt_buffer_append(&buffer, context_files[tool_index].path) != PSI_STATUS_OK ||
                psi_prompt_buffer_append(&buffer, "\n\n") != PSI_STATUS_OK ||
                psi_prompt_buffer_append(&buffer, context_files[tool_index].content) != PSI_STATUS_OK ||
                psi_prompt_buffer_append(&buffer, "\n\n") != PSI_STATUS_OK) {
                psi_prompt_buffer_free(&buffer);
                free(cwd);
                psi_prompt_free_context_files(context_files, index);
                return PSI_STATUS_ERROR;
            }
        }
    }

    if (psi_prompt_append_date_and_cwd(&buffer, cwd) != PSI_STATUS_OK) {
        psi_prompt_buffer_free(&buffer);
        free(cwd);
        psi_prompt_free_context_files(context_files, index);
        return PSI_STATUS_ERROR;
    }

    free(cwd);
    psi_prompt_free_context_files(context_files, index);
    *output_text = buffer.data;
    return PSI_STATUS_OK;
}
