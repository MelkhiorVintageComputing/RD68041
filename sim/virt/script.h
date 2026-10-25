// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68041

// rd-virt and rd-qvirt -- the console script: `expect <text>` waits for the
// text to appear in the console after the last match, `send <text>` types it
// (\n, \r, \t escapes); # starts a comment. sim/virt/linux/commands*.script.
#ifndef RDVIRT_SCRIPT_H
#define RDVIRT_SCRIPT_H

#include <cstdio>
#include <string>
#include <vector>

struct Script {
  struct Item { bool send; std::string text; };
  std::vector<Item> items;
  size_t pos = 0, seen = 0;
  bool load(const std::string &path) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return false;
    char line[4096];
    while (fgets(line, sizeof line, f)) {
      std::string l(line);
      while (!l.empty() && (l.back() == '\n' || l.back() == '\r')) l.pop_back();
      if (l.empty() || l[0] == '#') continue;
      bool send = l.compare(0, 5, "send ") == 0;
      bool exp = l.compare(0, 7, "expect ") == 0;
      if (!send && !exp) continue;
      std::string t = l.substr(send ? 5 : 7), u;
      for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == '\\' && i + 1 < t.size()) {
          char c = t[++i];
          u.push_back(c == 'n' ? '\n' : c == 'r' ? '\r' : c == 't' ? '\t' : c);
        } else {
          u.push_back(t[i]);
        }
      }
      items.push_back({send, u});
    }
    fclose(f);
    return true;
  }
  // What to type now, given the console so far.
  std::string poll(const std::string &cons) {
    std::string out;
    while (pos < items.size()) {
      Item &it = items[pos];
      if (it.send) { out += it.text; pos++; continue; }
      size_t at = cons.find(it.text, seen);
      if (at == std::string::npos) break;
      seen = at + it.text.size();
      pos++;
    }
    return out;
  }
  bool done() const { return pos >= items.size(); }
};

#endif
