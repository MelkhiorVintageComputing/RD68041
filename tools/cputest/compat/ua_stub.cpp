// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041
// Replaces od-win32/unicode.cpp for cputestgen on Linux (TCHAR == char).
#include <string.h>
#include <ctype.h>
char *ua(const char *s) { return strdup(s); }
char *au(const char *s) { return strdup(s); }
char *ua_copy(char *dst, int maxlen, const char *src) { strncpy(dst, src, maxlen); if (maxlen > 0) dst[maxlen - 1] = 0; return dst; }
void to_lower(char *s, int len) { if (len < 0) len = strlen(s); for (int i = 0; i < len && s[i]; i++) s[i] = tolower((unsigned char)s[i]); }
void to_upper(char *s, int len) { if (len < 0) len = strlen(s); for (int i = 0; i < len && s[i]; i++) s[i] = toupper((unsigned char)s[i]); }
int uaetcslen(const char *s) { return (int)strlen(s); }
