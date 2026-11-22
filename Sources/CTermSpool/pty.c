#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include "CTermSpool.h"
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

// Keep both ends outside stdio even when the caller has closed a standard FD.
static int prepare_descriptor(int *fd) {
    if (*fd > STDERR_FILENO) return fcntl(*fd, F_SETFD, FD_CLOEXEC);
    int copy = fcntl(*fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (copy < 0) return -1;
    close(*fd);
    *fd = copy;
    return 0;
}

int termspool_spawn_pty(const char *file, char *const argv[], char *const env[],
                        const char *directory, int *master) {
    int slave;
    struct winsize size = {.ws_row = 24, .ws_col = 80};
    if (openpty(master, &slave, NULL, NULL, &size)) return -1;
    pid_t pid = -1;
    char slave_name[128];
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    if (prepare_descriptor(master) || prepare_descriptor(&slave) ||
        ttyname_r(slave, slave_name, sizeof(slave_name)) ||
        fcntl(*master, F_SETFL, O_NONBLOCK) ||
        posix_spawn_file_actions_init(&actions)) goto done;

    // Open after setsid to acquire the controlling terminal in the child.
    if (posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slave_name, O_RDWR, 0) ||
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) ||
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) ||
        (directory && posix_spawn_file_actions_addchdir_np(&actions, directory)) ||
        posix_spawnattr_init(&attr)) goto destroy_actions;

    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigemptyset(&defaults);
    int signals[] = {SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD, SIGWINCH};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
        sigaddset(&defaults, signals[i]);
    if (posix_spawnattr_setsigmask(&attr, &mask) ||
        posix_spawnattr_setsigdefault(&attr, &defaults) ||
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) ||
        posix_spawn(&pid, file, &actions, &attr, argv, env)) pid = -1;
    posix_spawnattr_destroy(&attr);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
done:
    close(slave);
    if (pid < 0) close(*master);
    return pid;
}

int termspool_resize_pty(int master, unsigned short cols, unsigned short rows) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    return ioctl(master, TIOCSWINSZ, &size);
}
