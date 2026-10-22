/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright 2026 Romain Dolbeau */
/* Source location: https://github.com/MelkhiorVintageComputing/RD68041 */
/* Force-included (-include) when building WinUAE's cputestgen on Linux, where
 * WinUAE's od-unix port has TCHAR == char. */
#pragma once
#include <cwchar>
#include <cstdio>
#include <cstdarg>
#include <sys/stat.h>
#include <sys/types.h>
static inline int wprintf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vprintf(fmt, ap); va_end(ap); return r; }
static inline int _wmkdir(const char *p) { return mkdir(p, 0777); }
