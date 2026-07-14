#!/usr/bin/env python3
"""Single-pass workspace scanner: walk each project once (pruning
node_modules/.git/vendor) and apply all built-in rule sets, emitting the same
JSONL relationship records the legacy scanners/*.sh produced.

Contract: one JSON object per line, {"source","target","type","confidence","scanner"}.
"""
import os
import re
import sys
import json

PRUNE = {"node_modules", ".git", "vendor"}
MAX_DEPTH = 4  # deepest any rule needs (nginx/apisix at project depth 4)


def emit(source, target, type_, confidence, scanner):
    sys.stdout.write(json.dumps(
        {"source": source, "target": target, "type": type_,
         "confidence": confidence, "scanner": scanner}) + "\n")


def collect(workspace):
    """One pruned walk. Returns (files, projects).
    files: list of dicts {abspath, name, parts} where parts = path components
    relative to the workspace (parts[0] is the project dir name).
    projects: sorted list of non-hidden top-level project names."""
    files = []
    workspace = os.path.abspath(workspace)
    for root, dirs, names in os.walk(workspace):
        rel = os.path.relpath(root, workspace)
        depth = 0 if rel == "." else len(rel.split(os.sep))
        # prune unwanted dirs and stop descending past MAX_DEPTH
        dirs[:] = [d for d in dirs if d not in PRUNE and depth < MAX_DEPTH]
        for n in names:
            parts = ([] if rel == "." else rel.split(os.sep)) + [n]
            files.append({"abspath": os.path.join(root, n), "name": n, "parts": parts})
    projects = sorted(
        d for d in os.listdir(workspace)
        if os.path.isdir(os.path.join(workspace, d)) and not d.startswith("."))
    return files, projects


def project_of(f):
    return f["parts"][0] if len(f["parts"]) > 1 else None


def depth_from_project(f):
    # parts = [project, ..., name]; components below project root
    return len(f["parts"]) - 1


def depth_from_workspace(f):
    return len(f["parts"])


def read_lines(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


# ---------- docker-compose (workspace root, maxdepth 3) ----------
def rule_docker_compose(files):
    for f in files:
        if not re.match(r"docker-compose.*\.yml$", f["name"]):
            continue
        if depth_from_workspace(f) > 3:
            continue
        current = ""
        in_dep = False
        for line in read_lines(f["abspath"]):
            m = re.match(r"^ {2}([a-zA-Z0-9_-]+):\s*$", line)
            if m:
                current = m.group(1)
                if current in ("volumes", "networks", "configs", "secrets"):
                    current = ""
                in_dep = False
                continue
            if re.match(r"^\s*#", line):
                continue
            if current and re.match(r"^ {4}depends_on:", line):
                in_dep = True
                continue
            if in_dep and re.match(r"^ {4}[a-zA-Z]", line):
                in_dep = False
            if in_dep:
                m2 = re.match(r"^ {6}-\s*([a-zA-Z0-9_-]+)", line)
                if m2 and current and current != m2.group(1):
                    emit(current, m2.group(1), "infra", "high", "docker-compose")
                m3 = re.match(r"^ {6}([a-zA-Z0-9_-]+):\s*$", line)
                if m3 and current and current != m3.group(1) and m3.group(1) != "condition":
                    emit(current, m3.group(1), "infra", "high", "docker-compose")


# ---------- shared-db (project root, database*.yml maxdepth 3, .env* maxdepth 2) ----------
def rule_shared_db(files, projects):
    pairs = []  # (project, db_name)
    for f in files:
        proj = project_of(f)
        if proj is None or proj.startswith(".") or proj == "ito-dev-env-setup":
            continue
        if re.match(r"database.*\.yml$", f["name"]) and depth_from_project(f) <= 3:
            for line in read_lines(f["abspath"]):
                m = re.match(r"^\s*database:\s*([a-zA-Z0-9_][a-zA-Z0-9_-]*)\s*$", line)
                if m:
                    db = m.group(1)
                    if "test" in db or "ci" in db:
                        continue
                    pairs.append((proj, db))
        if (f["name"].startswith(".env") or f["name"] == "env.example") and depth_from_project(f) <= 2:
            for line in read_lines(f["abspath"]):
                if re.match(r"^\s*#", line):
                    continue
                m = re.match(r"^(DB_NAME|DATABASE_NAME|MYSQL_DATABASE|POSTGRES_DB)\s*=\s*[\"']*([a-zA-Z0-9_][a-zA-Z0-9_-]*)", line)
                if m:
                    db = m.group(2)
                    if "test" in db:
                        continue
                    pairs.append((proj, db))
    by_db = {}
    for proj, db in sorted(set(pairs)):
        by_db.setdefault(db, [])
        if proj not in by_db[db]:
            by_db[db].append(proj)
    for db, projs in by_db.items():
        if len(projs) < 2:
            continue
        for p in sorted(projs):
            emit(p, "mysql", "infra", "high", "shared-db")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: walk.py <workspace>\n")
        sys.exit(1)
    workspace = sys.argv[1]
    files, projects = collect(workspace)
    rule_docker_compose(files)
    rule_shared_db(files, projects)
    # api-calls, gateway-routes, shared-packages added in later tasks


if __name__ == "__main__":
    main()
