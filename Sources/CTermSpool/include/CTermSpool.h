#pragma once
#include <stddef.h>
int termspool_spawn_pty(const char *file, char *const argv[], char *const env[], const char *directory, int *master);
int termspool_resize_pty(int master, unsigned short cols, unsigned short rows);
