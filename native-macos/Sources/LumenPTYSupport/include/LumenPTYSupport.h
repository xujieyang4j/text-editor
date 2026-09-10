#ifndef LUMEN_PTY_SUPPORT_H
#define LUMEN_PTY_SUPPORT_H

#include <sys/types.h>

enum lumen_pty_failure_stage {
    LUMEN_PTY_FAILURE_NONE = 0,
    LUMEN_PTY_FAILURE_PIPE = 1,
    LUMEN_PTY_FAILURE_FORK = 2,
    LUMEN_PTY_FAILURE_CHDIR = 3,
    LUMEN_PTY_FAILURE_EXEC = 4,
    LUMEN_PTY_FAILURE_PARENT_READ = 5
};

/// Spawn one executable as a new session leader with a controlling pseudo-
/// terminal. argv and envp must already be null-terminated. The child side
/// performs only async-signal-safe operations between forkpty and execve.
/// Returns zero on exec success and -1 with failure_stage/error_code populated.
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
);

int lumen_pty_resize(int master_descriptor, unsigned short columns, unsigned short rows);
pid_t lumen_pty_foreground_process_group(int master_descriptor);
int lumen_pty_signal_process_group(pid_t process_group, int signal_number);
int lumen_pty_process_group_exists(pid_t process_group);

#endif
