# Usage: curl -o emoji.json https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json
#        python3 -I scripts/gen-emoji.py emoji.json Sources/Mtfy/Emoji.swift
import json, re, sys, unicodedata
data = json.load(open(sys.argv[1], encoding="utf-8"))
alias_re = re.compile(r"^[a-z0-9_+\-]{1,64}$")
out = {}
for e in data:
    emoji = e.get("emoji")
    if not isinstance(emoji, str) or not (1 <= len(emoji) <= 16):
        continue
    # Reject control characters (newer emoji may be unassigned in older Unicode tables, so allow those).
    def bad(c):
        cat = unicodedata.category(c)
        if cat == "Cn": return ord(c) < 0x1F000
        if cat == "Cf": return ord(c) not in (0x200D,)
        return cat in ("Cc", "Cs", "Co", "Zl", "Zp")
    if any(bad(c) for c in emoji) or any(c in '"\\' for c in emoji):
        continue
    for a in e.get("aliases", []):
        if isinstance(a, str) and alias_re.match(a) and a not in out:
            out[a] = emoji
lines = ["// Generated from github/gemoji db/emoji.json — the same shortcodes ntfy uses for tags.",
         "// Regenerate with scripts/gen-emoji.py; do not edit by hand.",
         "", "enum Emoji {", "    static let byTag: [String: String] = ["]
for k in sorted(out):
    lines.append(f'        "{k}": "{out[k]}",')
lines += ["    ]", "}", ""]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
print(len(out), "aliases")
