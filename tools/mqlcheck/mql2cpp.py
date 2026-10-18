#!/usr/bin/env python3
"""Translate an .mq5 file into C++ that g++ can syntax/type-check with mql5_shim.h.

Only the MQL5-specific syntax used by v10 is rewritten:
  - #property lines and 'input group' lines are dropped
  - 'input' declarations become 'extern const' (value unknown at compile time)
  - colour literals C'r,g,b' become 0
  - dynamic arrays 'T name[];' become 'MqlArray<T> name;'
  - array reference parameters 'T &name[]' become 'MqlArray<T> &name'
  - string-literal macros become std::string so that "a" + "b" works as in MQL5
"""
import re
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path, encoding="ascii") as fh:  # fails loudly on any non-ASCII byte
    lines = fh.read().split("\n")

out = ['#include "mql5_shim.h"']
for line in lines:
    s = line.strip()
    if s.startswith("#property") or s.startswith("input group"):
        out.append("")
        continue
    m = re.match(r'^(\s*#define\s+\w+\s+)("[^"]*")(.*)$', line)
    if m:
        line = f"{m.group(1)}string({m.group(2)}){m.group(3)}"
    # inputs: runtime constants (unknown value, cannot be assigned)
    line = re.sub(r"^(\s*)input\s+(\w+)\s+(\w+)\s*=[^;]*;.*$", r"\1extern const \2 \3;", line)
    line = re.sub(r"C'\d+,\d+,\d+'", "((color)0)", line)
    line = re.sub(r"^(\s*)(\w+)\s+(\w+)\[\];", r"\1MqlArray<\2> \3;", line)
    line = re.sub(r"\b(\w+)\s*&(\w+)\[\]", r"MqlArray<\1> &\2", line)
    out.append(line)

with open(out_path, "w") as fh:
    fh.write("\n".join(out))
