#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#include "psi/common.h"
#include "psi/process.h"

static const size_t PSI_PROCESS_OUTPUT_MAX_BYTES = 262144u;

static int psi_process_append_bytes(char **buffer, size_t *length, size_t *capacity, const char *data, size_t bytes) {
    char *next_buffer;
    size_t next_capacity;

    if (*length + bytes + 1u <= *capacity) {
        memcpy(*buffer + *length, data, bytes);
        *length += bytes;
        (*buffer)[*length] = '\0';
        return PSI_STATUS_OK;
    }

    next_capacity = *capacity == 0u ? 4096u : *capacity;
    while (*length + bytes + 1u > next_capacity) {
        next_capacity *= 2u;
    }

    next_buffer = (char *)realloc(*buffer, next_capacity);
    if (next_buffer == NULL) {
        return PSI_STATUS_ERROR;
    }

    *buffer = next_buffer;
    *capacity = next_capacity;
    memcpy(*buffer + *length, data, bytes);
    *length += bytes;
    (*buffer)[*length] = '\0';
    return PSI_STATUS_OK;
}

int psi_process_run_shell(const char *command, char **output_text, int *exit_status, int *truncated) {
#ifndef _WIN32
    int pipe_fds[2];
    pid_t child_pid;
    int wait_status;
    char read_buffer[4096];
    ssize_t read_count;
    char *output_buffer;
    size_t output_length;
    size_t output_capacity;
    size_t to_copy;

    if (command == NULL || output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    *output_text = NULL;
    *exit_status = -1;
    *truncated = 0;
    output_buffer = NULL;
    output_length = 0u;
    output_capacity = 0u;

    if (pipe(pipe_fds) != 0) {
        return PSI_STATUS_ERROR;
    }

    child_pid = fork();
    if (child_pid < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return PSI_STATUS_ERROR;
    }

    if (child_pid == 0) {
        close(pipe_fds[0]);
        dup2(pipe_fds[1], 1);
        dup2(pipe_fds[1], 2);
        close(pipe_fds[1]);
        execl("/bin/sh", "sh", "-lc", command, (char *)0);
        _exit(127);
    }

    close(pipe_fds[1]);
    for (;;) {
        read_count = read(pipe_fds[0], read_buffer, sizeof(read_buffer));
        if (read_count <= 0) {
            break;
        }

        if (output_length < PSI_PROCESS_OUTPUT_MAX_BYTES) {
            to_copy = (size_t)read_count;
            if (output_length + to_copy > PSI_PROCESS_OUTPUT_MAX_BYTES) {
                to_copy = PSI_PROCESS_OUTPUT_MAX_BYTES - output_length;
                *truncated = 1;
            }
            if (psi_process_append_bytes(&output_buffer, &output_length, &output_capacity, read_buffer, to_copy) != PSI_STATUS_OK) {
                close(pipe_fds[0]);
                waitpid(child_pid, &wait_status, 0);
                free(output_buffer);
                return PSI_STATUS_ERROR;
            }
            if ((size_t)read_count > to_copy) {
                *truncated = 1;
            }
        } else {
            *truncated = 1;
        }
    }
    close(pipe_fds[0]);

    if (waitpid(child_pid, &wait_status, 0) < 0) {
        free(output_buffer);
        return PSI_STATUS_ERROR;
    }

    if (WIFEXITED(wait_status)) {
        *exit_status = WEXITSTATUS(wait_status);
    } else if (WIFSIGNALED(wait_status)) {
        *exit_status = 128 + WTERMSIG(wait_status);
    } else {
        *exit_status = -1;
    }

    if (output_buffer == NULL) {
        output_buffer = psi_strdup("");
        if (output_buffer == NULL) {
            return PSI_STATUS_ERROR;
        }
    }

    *output_text = output_buffer;
    return PSI_STATUS_OK;
#else
    int status;

    if (command == NULL || output_text == NULL || exit_status == NULL || truncated == NULL) {
        return PSI_STATUS_ERROR;
    }

    status = system(command);
    *output_text = psi_strdup("");
    if (*output_text == NULL) {
        return PSI_STATUS_ERROR;
    }
    *exit_status = status;
    *truncated = 0;
    return PSI_STATUS_OK;
#endif
}
