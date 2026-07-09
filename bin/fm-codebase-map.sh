#!/usr/bin/env bash
# fm-codebase-map.sh - Emit compact project structure map via tldr or find.
# Best-effort: exits 0 even when tools fail. Usage: fm-codebase-map.sh [<dir>]
set -u
PROJ_DIR="${1:-$(pwd -P)}"
[ -d "$PROJ_DIR" ] || { echo "# (not a directory: $PROJ_DIR)"; exit 0; }

# Path 1: tldr structure -> exported (uppercase, non-test) symbols per package
command -v tldr >/dev/null 2>&1 && tldr_json=$(tldr structure "$PROJ_DIR" 2>/dev/null || true)
if [ -n "${tldr_json-}" ]; then
  result=$(echo "$tldr_json" | python3 -c '
import json, os, sys
data = json.loads(sys.stdin.buffer.read())
exports = []
for f in data.get("files", []):
    fpath = f.get("path","")
    if not fpath: continue
    exported = [d["name"] for d in f.get("definitions",[]) if d.get("name","") and d["name"][0].isupper() and not d["name"].startswith(("Test","Fuzz","Benchmark"))]
    if exported:
        pkg = os.path.dirname(fpath) or "root"
        exports.append((pkg, fpath, exported))
if len(exports) < 3:
    print("# project file tree")
    tree = {}
    for f in data.get("files",[]):
        fpath = f.get("path","")
        if not fpath: continue
        d = os.path.dirname(fpath) or "."
        tree.setdefault(d, []).append(os.path.basename(fpath))
    for d in sorted(tree, key=lambda k: (k==".",k)):
        print("  " + (d if d!="." else ".") + "/")
        for fn in sorted(tree[d]): print("    " + fn)
    sys.exit(0)
cap = int(os.environ.get("FM_CODEBASE_CAP","1550"))
chars, by_pkg = 0, {}
for pkg, fpath, symbols in exports: by_pkg.setdefault(pkg, []).append((fpath, symbols))
for pkg in sorted(by_pkg):
    if chars >= cap: break
    h = "# " + pkg; chars += len(h) + 1; print(h)
    for fpath, symbols in sorted(by_pkg[pkg]):
        if chars >= cap: break
        display = symbols[:8]
        line = "  " + fpath + ": " + ", ".join(display)
        if len(symbols) > 8: line += " (+" + str(len(symbols)-8) + ")"
        if chars + len(line) >= cap:
            r = cap - chars - 3
            if r > 20: print(line[:r] + "...")
            break
        print(line); chars += len(line) + 1
' 2>/dev/null) && [ "${#result}" -gt 40 ] && { echo "$result"; exit 0; }
fi

# Path 2: file tree via find (tldr unavailable, empty, or too sparse)
echo "# project file tree"
find "$PROJ_DIR" -maxdepth 3 -type f \( -name '*.go' -o -name '*.py' -o -name '*.ts' \
  -o -name '*.tsx' -o -name '*.rs' -o -name '*.sh' -o -name '*.js' -o -name '*.swift' \
  -o -name '*.c' -o -name '*.h' -o -name '*.java' -o -name '*.zig' \) \
  ! -path '*/vendor/*' ! -path '*/.git/*' ! -path '*/node_modules/*' \
  ! -path '*/target/*' ! -path '*/dist/*' 2>/dev/null \
  | sed "s|^$PROJ_DIR/||" | sort | head -20 | while IFS= read -r f; do echo "  $f"; done
