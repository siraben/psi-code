#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <cjson/cJSON.h>
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

static cJSON *psi_session_make_header(const struct psi_session *session) {
    cJSON *root;

    root = cJSON_CreateObject();
    if (root == NULL) {
        return NULL;
    }

    cJSON_AddStringToObject(root, "type", "session");
    cJSON_AddNumberToObject(root, "version", 1.0);
    cJSON_AddStringToObject(root, "id", session->id);
    return root;
}

static cJSON *psi_session_make_message(const struct psi_message *message) {
    cJSON *root;

    root = cJSON_CreateObject();
    if (root == NULL) {
        return NULL;
    }

    cJSON_AddStringToObject(root, "type", "message");
    cJSON_AddStringToObject(root, "role", psi_message_role_name(message->role));
    cJSON_AddStringToObject(root, "text", message->text ? message->text : "");
    return root;
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
    char line[16384];
    cJSON *root;
    cJSON *type;
    cJSON *id;
    cJSON *role;
    cJSON *text;
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
        root = cJSON_Parse(line);
        if (root == NULL) {
            continue;
        }

        type = cJSON_GetObjectItemCaseSensitive(root, "type");
        if (cJSON_IsString(type) && type->valuestring != NULL) {
            if (strcmp(type->valuestring, "session") == 0) {
                id = cJSON_GetObjectItemCaseSensitive(root, "id");
                if (cJSON_IsString(id) && id->valuestring != NULL) {
                    free(session->id);
                    session->id = psi_strdup(id->valuestring);
                    if (session->id == NULL) {
                        cJSON_Delete(root);
                        fclose(file);
                        return PSI_STATUS_ERROR;
                    }
                }
            } else if (strcmp(type->valuestring, "message") == 0) {
                role = cJSON_GetObjectItemCaseSensitive(root, "role");
                text = cJSON_GetObjectItemCaseSensitive(root, "text");
                if (cJSON_IsString(text) && text->valuestring != NULL) {
                    status = psi_session_append(
                        session,
                        psi_session_parse_role(cJSON_IsString(role) ? role->valuestring : NULL),
                        text->valuestring
                    );
                    if (status != PSI_STATUS_OK) {
                        cJSON_Delete(root);
                        fclose(file);
                        return PSI_STATUS_ERROR;
                    }
                }
            }
        }

        cJSON_Delete(root);
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
    cJSON *json;
    char *line;

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

    json = psi_session_make_header(session);
    if (json == NULL) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }
    line = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (line == NULL) {
        fclose(file);
        return PSI_STATUS_ERROR;
    }
    fprintf(file, "%s\n", line);
    free(line);

    for (index = 0u; index < session->count; index++) {
        json = psi_session_make_message(&session->messages[index]);
        if (json == NULL) {
            fclose(file);
            return PSI_STATUS_ERROR;
        }
        line = cJSON_PrintUnformatted(json);
        cJSON_Delete(json);
        if (line == NULL) {
            fclose(file);
            return PSI_STATUS_ERROR;
        }
        fprintf(file, "%s\n", line);
        free(line);
    }

    fclose(file);
    return PSI_STATUS_OK;
}
