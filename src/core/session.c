#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include "psi/session.h"

static int psi_session_clear_messages(struct psi_session *session) {
    size_t index;

    for (index = 0u; index < session->count; index++) {
        psi_message_free(&session->messages[index]);
    }

    free(session->messages);
    session->messages = NULL;
    session->count = 0u;
    session->capacity = 0u;
    return PSI_STATUS_OK;
}

static int psi_session_generate_id(struct psi_session *session) {
    char buffer[64];
    static unsigned long counter = 0ul;
    unsigned long now_value;

    now_value = (unsigned long)time(NULL);
    counter++;
    sprintf(buffer, "%lu-%lu", now_value, counter);

    free(session->id);
    session->id = psi_strdup(buffer);
    return session->id != NULL ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

static int psi_session_write_escaped(FILE *file, const char *text) {
    const unsigned char *ptr;

    fputc('"', file);
    if (text != NULL) {
        ptr = (const unsigned char *)text;
        while (*ptr != '\0') {
            switch (*ptr) {
                case '\\':
                    fputs("\\\\", file);
                    break;
                case '"':
                    fputs("\\\"", file);
                    break;
                case '\n':
                    fputs("\\n", file);
                    break;
                case '\r':
                    fputs("\\r", file);
                    break;
                case '\t':
                    fputs("\\t", file);
                    break;
                default:
                    fputc((int)*ptr, file);
                    break;
            }
            ptr++;
        }
    }
    fputc('"', file);
    return PSI_STATUS_OK;
}

static int psi_session_write_header(FILE *file, const struct psi_session *session) {
    fputs("{\"type\":\"session\",\"version\":1,\"id\":", file);
    psi_session_write_escaped(file, session->id);
    fputs("}\n", file);
    return PSI_STATUS_OK;
}

static int psi_session_write_message(FILE *file, const struct psi_message *message) {
    fputs("{\"type\":\"message\",\"role\":", file);
    psi_session_write_escaped(file, psi_message_role_name(message->role));
    fputs(",\"text\":", file);
    psi_session_write_escaped(file, message->text);
    fputs("}\n", file);
    return PSI_STATUS_OK;
}

static int psi_session_ensure_parent_dir(const char *path) {
    char *dir_path;
    char *scan;

    dir_path = psi_strdup(path);
    if (dir_path == NULL) {
        return PSI_STATUS_ERROR;
    }

    scan = strrchr(dir_path, '/');
    if (scan == NULL) {
        free(dir_path);
        return PSI_STATUS_OK;
    }

    if (scan == dir_path) {
        scan[1] = '\0';
    } else {
        *scan = '\0';
    }

    for (scan = dir_path + 1; *scan != '\0'; scan++) {
        if (*scan == '/') {
            *scan = '\0';
            if (mkdir(dir_path, 0777) != 0 && errno != EEXIST) {
                perror("mkdir");
                free(dir_path);
                return PSI_STATUS_ERROR;
            }
            *scan = '/';
        }
    }

    if (mkdir(dir_path, 0777) != 0 && errno != EEXIST) {
        perror("mkdir");
        free(dir_path);
        return PSI_STATUS_ERROR;
    }

    free(dir_path);
    return PSI_STATUS_OK;
}

static const char *psi_session_find_json_string(const char *line, const char *key) {
    size_t key_length;
    const char *match;

    key_length = strlen(key);
    match = strstr(line, key);
    if (match == NULL) {
        return NULL;
    }

    return match + key_length;
}

static char *psi_session_parse_json_string(const char *line, const char *key) {
    const char *start;
    char *buffer;
    size_t length;
    size_t out_index;

    start = psi_session_find_json_string(line, key);
    if (start == NULL) {
        return NULL;
    }

    buffer = (char *)malloc(strlen(start) + 1u);
    if (buffer == NULL) {
        return NULL;
    }

    out_index = 0u;
    length = 0u;
    while (start[length] != '\0') {
        if (start[length] == '"' && (length == 0u || start[length - 1u] != '\\')) {
            break;
        }
        if (start[length] == '\\') {
            length++;
            if (start[length] == '\0') {
                break;
            }
            switch (start[length]) {
                case 'n':
                    buffer[out_index++] = '\n';
                    break;
                case 'r':
                    buffer[out_index++] = '\r';
                    break;
                case 't':
                    buffer[out_index++] = '\t';
                    break;
                case '\\':
                    buffer[out_index++] = '\\';
                    break;
                case '"':
                    buffer[out_index++] = '"';
                    break;
                default:
                    buffer[out_index++] = start[length];
                    break;
            }
        } else {
            buffer[out_index++] = start[length];
        }
        length++;
    }

    buffer[out_index] = '\0';
    return buffer;
}

static enum psi_message_role psi_session_parse_role(const char *role_name) {
    if (role_name == NULL) {
        return PSI_MESSAGE_CUSTOM;
    }
    if (strcmp(role_name, "user") == 0) {
        return PSI_MESSAGE_USER;
    }
    if (strcmp(role_name, "assistant") == 0) {
        return PSI_MESSAGE_ASSISTANT;
    }
    if (strcmp(role_name, "tool-call") == 0) {
        return PSI_MESSAGE_TOOL_CALL;
    }
    if (strcmp(role_name, "tool-result") == 0) {
        return PSI_MESSAGE_TOOL_RESULT;
    }
    if (strcmp(role_name, "branch-summary") == 0) {
        return PSI_MESSAGE_BRANCH_SUMMARY;
    }
    if (strcmp(role_name, "compaction-summary") == 0) {
        return PSI_MESSAGE_COMPACTION_SUMMARY;
    }
    return PSI_MESSAGE_CUSTOM;
}

void psi_session_init(struct psi_session *session) {
    if (session == NULL) {
        return;
    }

    session->messages = NULL;
    session->count = 0u;
    session->capacity = 0u;
    session->id = NULL;
    session->path = NULL;
}

void psi_session_free(struct psi_session *session) {
    if (session == NULL) {
        return;
    }

    psi_session_clear_messages(session);
    free(session->id);
    free(session->path);
    session->id = NULL;
    session->path = NULL;
}

int psi_session_append(struct psi_session *session, enum psi_message_role role, const char *text) {
    struct psi_message *new_messages;
    size_t new_capacity;

    if (session == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (session->count == session->capacity) {
        new_capacity = session->capacity == 0u ? 8u : session->capacity * 2u;
        new_messages = (struct psi_message *)realloc(session->messages, new_capacity * sizeof(struct psi_message));
        if (new_messages == NULL) {
            return PSI_STATUS_ERROR;
        }
        session->messages = new_messages;
        session->capacity = new_capacity;
    }

    psi_message_init(&session->messages[session->count], role, text);
    if (session->messages[session->count].text == NULL) {
        return PSI_STATUS_ERROR;
    }

    session->count++;
    return PSI_STATUS_OK;
}

int psi_session_set_path(struct psi_session *session, const char *path) {
    char *copy;

    if (session == NULL) {
        return PSI_STATUS_ERROR;
    }

    if (path == NULL) {
        free(session->path);
        session->path = NULL;
        return PSI_STATUS_OK;
    }

    copy = psi_strdup(path);
    if (copy == NULL) {
        return PSI_STATUS_ERROR;
    }

    free(session->path);
    session->path = copy;
    return PSI_STATUS_OK;
}

int psi_session_load(struct psi_session *session, const char *path) {
    FILE *file;
    char line[8192];
    char *type_value;
    char *id_value;
    char *role_value;
    char *text_value;
    int status;

    if (session == NULL || path == NULL) {
        return PSI_STATUS_ERROR;
    }

    file = fopen(path, "r");
    if (file == NULL) {
        status = psi_session_set_path(session, path);
        if (status != PSI_STATUS_OK) {
            return status;
        }
        if (session->id == NULL) {
            return psi_session_generate_id(session);
        }
        return PSI_STATUS_OK;
    }

    psi_session_clear_messages(session);
    if (psi_session_set_path(session, path) != PSI_STATUS_OK) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }

    while (fgets(line, sizeof(line), file) != NULL) {
        type_value = psi_session_parse_json_string(line, "\"type\":\"");
        if (type_value == NULL) {
            continue;
        }

        if (strcmp(type_value, "session") == 0) {
            id_value = psi_session_parse_json_string(line, "\"id\":\"");
            if (id_value != NULL) {
                free(session->id);
                session->id = id_value;
            }
        } else if (strcmp(type_value, "message") == 0) {
            role_value = psi_session_parse_json_string(line, "\"role\":\"");
            text_value = psi_session_parse_json_string(line, "\"text\":\"");
            if (text_value != NULL) {
                status = psi_session_append(session, psi_session_parse_role(role_value), text_value);
                free(text_value);
                if (status != PSI_STATUS_OK) {
                    free(role_value);
                    free(type_value);
                    fclose(file);
                    return PSI_STATUS_ERROR;
                }
            }
            free(role_value);
        }

        free(type_value);
    }

    fclose(file);

    if (session->id == NULL) {
        return psi_session_generate_id(session);
    }
    return PSI_STATUS_OK;
}

int psi_session_save(struct psi_session *session) {
    FILE *file;
    size_t index;

    if (session == NULL || session->path == NULL) {
        return PSI_STATUS_OK;
    }

    if (session->id == NULL && psi_session_generate_id(session) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    if (psi_session_ensure_parent_dir(session->path) != PSI_STATUS_OK) {
        return PSI_STATUS_ERROR;
    }

    file = fopen(session->path, "w");
    if (file == NULL) {
        perror("fopen");
        return PSI_STATUS_ERROR;
    }

    psi_session_write_header(file, session);
    for (index = 0u; index < session->count; index++) {
        psi_session_write_message(file, &session->messages[index]);
    }

    fclose(file);
    return PSI_STATUS_OK;
}
