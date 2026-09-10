#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L

#include "LumenPTYSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

#ifndef F_SETNOSIGPIPE
#define F_SETNOSIGPIPE 73
#endif

struct lumen_pty_child_failure {
    int stage;
    int error_code;
};

static void lumen_pty_child_fail(int descriptor, int stage, int error_code) {
    struct lumen_pty_child_failure failure = { stage, error_code };
    const char *cursor = (const char *)&failure;
    size_t remaining = sizeof(failure);
    while (remaining > 0) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count > 0) {
            cursor += count;
            remaining -= (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    _exit(stage == LUMEN_PTY_FAILURE_CHDIR ? 126 : 127);
}

static void lumen_pty_reap_failed_child(pid_t child) {
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

int lumen_pty_spawn(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    unsigned short columns,
    unsigned short rows,
    pid_t *child_pid,
    int *master_descriptor,
    int *failure_stage,
    int *error_code
) {
    if (child_pid == NULL || master_descriptor == NULL || failure_stage == NULL
        || error_code == NULL) {
        errno = EINVAL;
        return -1;
    }
    *child_pid = 0;
    *master_descriptor = -1;
    *failure_stage = LUMEN_PTY_FAILURE_NONE;
    *error_code = 0;

    int status_pipe[2] = { -1, -1 };
    if (pipe(status_pipe) != 0) {
        *failure_stage = LUMEN_PTY_FAILURE_PIPE;
        *error_code = errno;
        return -1;
    }
    int status_read = fcntl(status_pipe[0], F_DUPFD, 10);
    if (status_read < 0 || fcntl(status_read, F_SETFD, FD_CLOEXEC) != 0) {
        *failure_stage = LUMEN_PTY_FAILURE_PIPE;
        *error_code = errno;
        close(status_pipe[0]);
        close(status_pipe[1]);
        if (status_read >= 0) close(status_read);
        return -1;
    }
    int status_write = fcntl(status_pipe[1], F_DUPFD, 10);
    if (status_write < 0 || fcntl(status_write, F_SETFD, FD_CLOEXEC) != 0) {
        *failure_stage = LUMEN_PTY_FAILURE_PIPE;
        *error_code = errno;
        close(status_pipe[0]);
        close(status_pipe[1]);
        close(status_read);
        if (status_write >= 0) close(status_write);
        return -1;
    }
    close(status_pipe[0]);
    close(status_pipe[1]);

    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = columns;
    size.ws_row = rows;
    long maximum_descriptor = sysconf(_SC_OPEN_MAX);
    if (maximum_descriptor < 0) maximum_descriptor = 1024;

    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) {
        *failure_stage = LUMEN_PTY_FAILURE_FORK;
        *error_code = errno;
        close(status_read);
        close(status_write);
        return -1;
    }
    if (child == 0) {
        close(status_read);
        // forkpty cannot provide posix_spawn's CLOEXEC_DEFAULT. Preserve one
        // launch-status descriptor at a known number, then close every other
        // application descriptor before entering workspace-controlled code.
        const int child_status_descriptor = 3;
        if (status_write != child_status_descriptor) {
            if (dup2(status_write, child_status_descriptor) < 0) {
                lumen_pty_child_fail(
                    status_write, LUMEN_PTY_FAILURE_PIPE, errno
                );
            }
            close(status_write);
        }
        if (fcntl(child_status_descriptor, F_SETFD, FD_CLOEXEC) != 0) {
            lumen_pty_child_fail(
                child_status_descriptor, LUMEN_PTY_FAILURE_PIPE, errno
            );
        }
        for (int descriptor = child_status_descriptor + 1;
             descriptor < maximum_descriptor; descriptor++) {
            close(descriptor);
        }
        if (chdir(working_directory) != 0) {
            lumen_pty_child_fail(
                child_status_descriptor, LUMEN_PTY_FAILURE_CHDIR, errno
            );
        }
        execve(executable, argv, envp);
        lumen_pty_child_fail(
            child_status_descriptor, LUMEN_PTY_FAILURE_EXEC, errno
        );
    }

    close(status_write);
    struct lumen_pty_child_failure failure;
    char *cursor = (char *)&failure;
    size_t received = 0;
    while (received < sizeof(failure)) {
        ssize_t count = read(
            status_read, cursor + received, sizeof(failure) - received
        );
        if (count > 0) {
            received += (size_t)count;
        } else if (count == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            *failure_stage = LUMEN_PTY_FAILURE_PARENT_READ;
            *error_code = errno;
            close(status_read);
            close(master);
            kill(child, SIGKILL);
            lumen_pty_reap_failed_child(child);
            return -1;
        }
    }
    close(status_read);

    if (received != 0) {
        *failure_stage = received == sizeof(failure)
            ? failure.stage : LUMEN_PTY_FAILURE_PARENT_READ;
        *error_code = received == sizeof(failure) ? failure.error_code : EIO;
        close(master);
        lumen_pty_reap_failed_child(child);
        return -1;
    }

    int master_flags = fcntl(master, F_GETFL);
    if (master_flags < 0
        || fcntl(master, F_SETFD, FD_CLOEXEC) != 0
        || fcntl(master, F_SETFL, master_flags | O_NONBLOCK) != 0
        || fcntl(master, F_SETNOSIGPIPE, 1) != 0) {
        *failure_stage = LUMEN_PTY_FAILURE_PIPE;
        *error_code = errno;
        close(master);
        kill(-child, SIGKILL);
        kill(child, SIGKILL);
        lumen_pty_reap_failed_child(child);
        return -1;
    }

    *child_pid = child;
    *master_descriptor = master;
    return 0;
}

int lumen_pty_resize(int master_descriptor, unsigned short columns, unsigned short rows) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = columns;
    size.ws_row = rows;
    return ioctl(master_descriptor, TIOCSWINSZ, &size);
}

pid_t lumen_pty_foreground_process_group(int master_descriptor) {
    return tcgetpgrp(master_descriptor);
}

int lumen_pty_signal_process_group(pid_t process_group, int signal_number) {
    if (process_group <= 1) {
        errno = EINVAL;
        return -1;
    }
    return kill(-process_group, signal_number);
}

int lumen_pty_process_group_exists(pid_t process_group) {
    if (process_group <= 1) return 0;
    if (kill(-process_group, 0) == 0 || errno == EPERM) return 1;
    if (errno == ESRCH) return 0;
    return -1;
}
