#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cjson/cJSON.h>
#include <editline/readline.h>
#include "psi/agent.h"
#include "psi/runtime.h"
#include "psi/session.h"
#include "psi/vm.h"

struct psi_cli_render_state {
    struct psi_vm *vm;
    int assistant_wrote_text;
};

static int psi_print_render_event(struct psi_vm *vm, const char *event_name, cJSON *payload) {
    char *payload_json;
    char *rendered_text;
    int status;

    payload_json = NULL;
    rendered_text = NULL;
    status = PSI_STATUS_OK;

    if (payload != NULL) {
        payload_json = cJSON_PrintUnformatted(payload);
        if (payload_json == NULL) {
            return PSI_STATUS_ERROR;
        }
    }

    status = psi_vm_render_event_json(vm, event_name, payload_json, &rendered_text);
    free(payload_json);
    if (status != PSI_STATUS_OK) {
        free(rendered_text);
        return status;
    }

    if (rendered_text != NULL && rendered_text[0] != '\0') {
        fputs(rendered_text, stdout);
        fflush(stdout);
    }
    free(rendered_text);
    return PSI_STATUS_OK;
}

static void psi_cli_observer_text_delta(void *userdata, const char *text) {
    struct psi_cli_render_state *state;
    cJSON *payload;

    state = (struct psi_cli_render_state *)userdata;
    if (state == NULL || state->vm == NULL) {
        return;
    }

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return;
    }
    cJSON_AddStringToObject(payload, "text", text != NULL ? text : "");
    if (psi_print_render_event(state->vm, "assistant-text", payload) == PSI_STATUS_OK &&
        text != NULL && text[0] != '\0') {
        state->assistant_wrote_text = 1;
    }
    cJSON_Delete(payload);
}

static void psi_cli_observer_tool_call(void *userdata, const char *tool_call_id, const char *tool_name, const char *input_json) {
    struct psi_cli_render_state *state;
    cJSON *payload;
    cJSON *input_value;

    state = (struct psi_cli_render_state *)userdata;
    if (state == NULL || state->vm == NULL) {
        return;
    }

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return;
    }
    cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
    cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "");
    input_value = input_json != NULL ? cJSON_Parse(input_json) : NULL;
    if (input_value == NULL) {
        input_value = cJSON_CreateObject();
    }
    cJSON_AddItemToObject(payload, "input", input_value);
    psi_print_render_event(state->vm, "tool-call", payload);
    cJSON_Delete(payload);
}

static void psi_cli_observer_tool_result(void *userdata, const char *tool_call_id, const char *tool_name, const char *output_json) {
    struct psi_cli_render_state *state;
    cJSON *payload;
    cJSON *result_value;

    state = (struct psi_cli_render_state *)userdata;
    if (state == NULL || state->vm == NULL) {
        return;
    }

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return;
    }
    cJSON_AddStringToObject(payload, "id", tool_call_id != NULL ? tool_call_id : "");
    cJSON_AddStringToObject(payload, "tool", tool_name != NULL ? tool_name : "");
    result_value = output_json != NULL ? cJSON_Parse(output_json) : NULL;
    if (result_value == NULL) {
        result_value = cJSON_CreateObject();
        if (output_json != NULL) {
            cJSON_AddStringToObject(result_value, "raw", output_json);
        }
    }
    cJSON_AddItemToObject(payload, "result", result_value);
    psi_print_render_event(state->vm, "tool-result", payload);
    cJSON_Delete(payload);
}

static int psi_run_agent_turn_with_cli_hooks(
    struct psi_agent_runtime *runtime,
    const char *user_text,
    char **response_text
) {
    struct psi_cli_render_state render_state;
    struct psi_agent_observer observer;
    cJSON *payload;
    int status;

    render_state.vm = &runtime->vm;
    render_state.assistant_wrote_text = 0;

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return PSI_STATUS_ERROR;
    }
    cJSON_AddStringToObject(payload, "text", user_text != NULL ? user_text : "");
    status = psi_print_render_event(&runtime->vm, "before-turn", payload);
    cJSON_Delete(payload);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    observer.userdata = &render_state;
    observer.on_assistant_text_delta = psi_cli_observer_text_delta;
    observer.on_tool_call = psi_cli_observer_tool_call;
    observer.on_tool_result = psi_cli_observer_tool_result;

    status = psi_agent_runtime_turn_with_observer(runtime, user_text, &observer, response_text);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    payload = cJSON_CreateObject();
    if (payload == NULL) {
        return PSI_STATUS_ERROR;
    }
    cJSON_AddStringToObject(payload, "text", *response_text != NULL ? *response_text : "");
    cJSON_AddBoolToObject(payload, "assistant-streamed", render_state.assistant_wrote_text);
    status = psi_print_render_event(&runtime->vm, "after-turn", payload);
    cJSON_Delete(payload);
    return status;
}

static int psi_run_eval_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    char *output_text;
    int status;

    output_text = NULL;
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    status = psi_vm_eval_to_string(&vm, options->payload, &output_text);
    if (status == PSI_STATUS_OK && output_text != NULL) {
        printf("%s\n", output_text);
    }

    free(output_text);
    psi_vm_destroy(&vm);
    return status;
}

int psi_run_print_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    struct psi_session session;
    char *reply_text;
    int status;

    reply_text = NULL;
    psi_session_init(&session);
    if (options->session_file != NULL) {
        if (psi_session_load(&session, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_session_free(&session);
            return PSI_STATUS_ERROR;
        }
    }

    if (psi_session_append(&session, PSI_MESSAGE_USER, options->payload) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to append user message\n");
        psi_session_free(&session);
        return PSI_STATUS_ERROR;
    }

    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        psi_session_free(&session);
        return status;
    }
    psi_vm_bind_session(&vm, &session);

    status = psi_vm_call_string_procedure(&vm, "psi-handle-print", options->payload, &reply_text);
    if (status != PSI_STATUS_OK) {
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return status;
    }

    if (psi_session_append(&session, PSI_MESSAGE_ASSISTANT, reply_text) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to append assistant message\n");
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return PSI_STATUS_ERROR;
    }

    if (psi_session_save(&session) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_vm_destroy(&vm);
        psi_session_free(&session);
        free(reply_text);
        return PSI_STATUS_ERROR;
    }

    printf("%s\n", reply_text);

    psi_vm_destroy(&vm);
    psi_session_free(&session);
    free(reply_text);
    return PSI_STATUS_OK;
}

int psi_run_repl(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *action_name;
    char *action_text;
    char *line;
    char *response_text;
    char *summary_text;
    long keep_recent;
    int status;

    action_name = NULL;
    action_text = NULL;
    line = NULL;
    response_text = NULL;
    summary_text = NULL;
    status = psi_agent_runtime_init(&runtime, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (options->session_file != NULL) {
        if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_agent_runtime_free(&runtime);
            return PSI_STATUS_ERROR;
        }
    }

    printf("psi coding agent\n");
    printf("type a prompt to run the agent, /help for commands, or /quit to exit\n");

    status = PSI_STATUS_OK;
    for (;;) {
        line = readline("psi> ");
        if (line == NULL) {
            break;
        }

        if (strcmp(line, "/quit") == 0 || strcmp(line, "/q") == 0 ||
            strcmp(line, ":quit") == 0 || strcmp(line, ":q") == 0) {
            free(line);
            line = NULL;
            break;
        }

        if (line[0] == '/') {
            free(action_name);
            free(action_text);
            action_name = NULL;
            action_text = NULL;
            status = psi_vm_parse_command(&runtime.vm, line, &action_name, &action_text, &keep_recent);
            if (status != PSI_STATUS_OK) {
                free(line);
                line = NULL;
                break;
            }

            free(line);
            line = NULL;
            if (action_name != NULL) {
                if (strcmp(action_name, "print") == 0) {
                    printf("%s\n", action_text != NULL ? action_text : "");
                    continue;
                }
                if (strcmp(action_name, "compact") == 0) {
                    free(summary_text);
                    summary_text = NULL;
                    status = psi_agent_runtime_compact(&runtime, (size_t)keep_recent, &summary_text);
                    if (status != PSI_STATUS_OK) {
                        fprintf(stderr, "failed to compact session\n");
                        break;
                    }
                    if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
                        fprintf(stderr, "failed to save session file\n");
                        status = PSI_STATUS_ERROR;
                        break;
                    }
                    printf("compaction summary:\n%s\n", summary_text != NULL ? summary_text : "");
                    continue;
                }
            }
            fprintf(stderr, "unknown command\n");
            continue;
        }

        if (line[0] != '\0') {
            add_history(line);
        }

        free(response_text);
        response_text = NULL;
        status = psi_run_agent_turn_with_cli_hooks(&runtime, line, &response_text);
        free(line);
        line = NULL;
        if (status != PSI_STATUS_OK) {
            continue;
        }

        if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to save session file\n");
            status = PSI_STATUS_ERROR;
            break;
        }
    }

    free(line);
    free(action_name);
    free(action_text);
    free(response_text);
    free(summary_text);
    psi_agent_runtime_free(&runtime);
    return status == PSI_STATUS_OK ? PSI_STATUS_OK : PSI_STATUS_ERROR;
}

int psi_run_system_prompt_mode(const struct psi_cli_options *options) {
    struct psi_vm vm;
    char *output_text;
    int status;

    output_text = NULL;
    status = psi_vm_init(&vm, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }

    status = psi_vm_call_procedure0_to_string(&vm, "psi-handle-system-prompt", &output_text);
    if (status == PSI_STATUS_OK && output_text != NULL) {
        printf("%s\n", output_text);
    }

    free(output_text);
    psi_vm_destroy(&vm);
    return status;
}

int psi_run_agent_mode(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *response_text;
    int status;

    response_text = NULL;
    status = psi_agent_runtime_init(&runtime, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (options->session_file != NULL) {
        if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
            fprintf(stderr, "failed to load session file: %s\n", options->session_file);
            psi_agent_runtime_free(&runtime);
            return PSI_STATUS_ERROR;
        }
    }

    status = psi_run_agent_turn_with_cli_hooks(&runtime, options->payload, &response_text);
    if (status != PSI_STATUS_OK) {
        psi_agent_runtime_free(&runtime);
        free(response_text);
        return status;
    }

    if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_agent_runtime_free(&runtime);
        free(response_text);
        return PSI_STATUS_ERROR;
    }

    psi_agent_runtime_free(&runtime);
    free(response_text);
    return PSI_STATUS_OK;
}

int psi_run_compact_mode(const struct psi_cli_options *options) {
    struct psi_agent_runtime runtime;
    char *summary_text;
    int status;

    if (options->session_file == NULL) {
        fprintf(stderr, "--compact requires --session FILE\n");
        return PSI_STATUS_ERROR;
    }

    summary_text = NULL;
    status = psi_agent_runtime_init(&runtime, options->boot_file, stdin, stdout, stderr);
    if (status != PSI_STATUS_OK) {
        return status;
    }
    psi_agent_runtime_configure(&runtime, options->model, options->max_tokens);
    if (psi_agent_runtime_load_session(&runtime, options->session_file) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to load session file: %s\n", options->session_file);
        psi_agent_runtime_free(&runtime);
        return PSI_STATUS_ERROR;
    }

    status = psi_agent_runtime_compact(&runtime, (size_t)options->keep_recent, &summary_text);
    if (status != PSI_STATUS_OK) {
        psi_agent_runtime_free(&runtime);
        free(summary_text);
        return status;
    }
    if (psi_agent_runtime_save(&runtime) != PSI_STATUS_OK) {
        fprintf(stderr, "failed to save session file\n");
        psi_agent_runtime_free(&runtime);
        free(summary_text);
        return PSI_STATUS_ERROR;
    }

    printf("%s\n", summary_text != NULL ? summary_text : "");
    psi_agent_runtime_free(&runtime);
    free(summary_text);
    return PSI_STATUS_OK;
}

static int psi_run_by_mode(const struct psi_cli_options *options) {
    switch (options->mode) {
        case PSI_CLI_MODE_PRINT:
            return psi_run_print_mode(options);
        case PSI_CLI_MODE_EVAL:
            return psi_run_eval_mode(options);
        case PSI_CLI_MODE_REPL:
            return psi_run_repl(options);
        case PSI_CLI_MODE_SYSTEM_PROMPT:
            return psi_run_system_prompt_mode(options);
        case PSI_CLI_MODE_AGENT:
            return psi_run_agent_mode(options);
        case PSI_CLI_MODE_COMPACT:
            return psi_run_compact_mode(options);
        default:
            return PSI_STATUS_ERROR;
    }
}

int psi_run_print_mode_dispatch(const struct psi_cli_options *options) {
    return psi_run_by_mode(options);
}
