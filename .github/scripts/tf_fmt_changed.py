#!/usr/bin/env python3
"""`terraform fmt -check`, limited to the lines a change adds or edits.

Existing files carry formatting drift; failing on it would block every PR that
touches them. This formats each changed .tf/.tfvars file as of <head> and
fails only where terraform fmt would change a line the diff touched.

Usage: tf_fmt_changed.py <base> <head>
"""
import difflib
import re
import subprocess
import sys


def run(*cmd, stdin=None):
    return subprocess.run(cmd, input=stdin, check=True, capture_output=True, text=True).stdout


def touched_lines(base, head, path):
    lines = set()
    for m in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", run("git", "diff", "-U0", base, head, "--", path), re.M):
        start, count = int(m.group(1)), int(m.group(2) or 1)
        lines.update(range(start, start + count))
    return lines


def main(base, head):
    base = run("git", "merge-base", base, head).strip()
    head = run("git", "rev-parse", head).strip()
    files = [f for f in run("git", "diff", "--name-only", "--diff-filter=AMR", base, head).splitlines()
             if f.endswith((".tf", ".tfvars"))]
    bad = []
    for path in files:
        src = run("git", "show", f"{head}:{path}")
        p = subprocess.run(["terraform", "fmt", "-no-color", "-"], input=src, capture_output=True, text=True)
        if p.returncode != 0:
            bad.append(f"{path}: terraform fmt can't parse it:\n{p.stderr}")
            continue
        old, new = src.splitlines(), p.stdout.splitlines()
        touched = touched_lines(base, head, path)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
            if tag == "equal":
                continue
            hit = sorted(n for n in range(i1 + 1, max(i2, i1 + 1) + 1) if n in touched)
            if hit:  # line numbers only: echoing content could print a leaked secret
                bad.append(f"{path}: lines {', '.join(map(str, hit))} not terraform-fmt formatted")
    print(f"checked {len(files)} changed Terraform file(s) {base[:12]}..{head[:12]}")
    if bad:
        print("FAIL: run `terraform fmt` on the lines you changed:\n" + "\n".join(bad))
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
