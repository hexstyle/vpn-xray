#!/usr/bin/env python3
"""Generate the node-summary table in docs/DIAGNOSTIC-TREE.md from the node
manifest — the single source of truth (docs/UNIFIED-DIAGNOSTIC-UI-DESIGN.md).
Keeps the doc's summary from drifting against the runtime/UI.

  python3 gen-tree-doc.py           # rewrite the table in place
  python3 gen-tree-doc.py --check   # exit 1 if the doc is out of sync
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
MANIFEST = os.path.join(ROOT, "routers/common/files/diag/nodes.manifest")
DOC = os.path.join(ROOT, "docs/DIAGNOSTIC-TREE.md")
BEGIN = "<!-- BEGIN generated node table (common/lib/diag/gen-tree-doc.py) -->"
END = "<!-- END generated node table -->"


def build_table():
    rows = []
    with open(MANIFEST) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            f = line.split("|")
            if len(f) != 10:
                continue
            i, parent, layer, title, side, risk, repair, auto, ui_slot, gap = f
            rows.append((i, layer, title, side, risk, repair or "—", auto or "none", gap or "—"))
    out = [
        BEGIN,
        "*Generated from `routers/common/files/diag/nodes.manifest` — do not edit by hand.*",
        "",
        "| id | layer | title | side | risk | repair | auto | gap |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in rows:
        out.append("| " + " | ".join(r) + " |")
    out.append(END)
    return "\n".join(out)


def main():
    doc = open(DOC).read()
    tbl = build_table()
    if BEGIN in doc and END in doc:
        new = re.sub(re.escape(BEGIN) + ".*?" + re.escape(END), lambda _: tbl, doc, flags=re.S)
    else:
        new = doc.replace("## 0. Entry", tbl + "\n\n## 0. Entry", 1)
    if "--check" in sys.argv:
        sys.exit(0 if new == doc else 1)
    if new != doc:
        open(DOC, "w").write(new)
        print("updated", os.path.relpath(DOC, ROOT))
    else:
        print("up to date")


if __name__ == "__main__":
    main()
