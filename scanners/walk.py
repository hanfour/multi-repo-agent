#!/usr/bin/env python3
"""Single-pass workspace scanner: walk each project once (pruning
node_modules/.git/vendor) and apply all built-in rule sets, emitting the same
JSONL relationship records the legacy scanners/*.sh produced.

Contract: one JSON object per line, {"source","target","type","confidence","scanner"}.
"""
import fnmatch
import os
import re
import sys
import json

PRUNE = {"node_modules", ".git", "vendor"}
MAX_DEPTH = 4  # deepest any rule needs (nginx/apisix at project depth 4)

# Known port -> service mappings (from docker-compose conventions)
PORT_TO_SERVICE = {
    "4000": "erp", "4001": "billing", "4500": "api-gateway", "5000": "catalog",
    "3100": "finance-system", "5173": "web-ui", "3030": "oss-ui-v2",
    "9443": "partner-api-gateway",
}
# Known hostname -> service mappings (service name patterns)
HOST_TO_SERVICE = {
    "erp": "erp", "billing": "billing", "catalog": "catalog",
    "api-gateway": "api-gateway", "api_gateway": "api-gateway",
    "finance-system": "finance-system", "finance_system": "finance-system",
    "web-ui": "web-ui",
}


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


def _known_upper(name):
    # bash: known_upper="${known^^}"; known_upper="${known_upper//-/_}"
    return name.upper().replace("-", "_")


# ---------- api-calls (.env*/env.example, project depth <=2) ----------
def rule_api_calls(files, projects):
    proj_set = set(projects)
    for f in files:
        proj = project_of(f)
        if proj is None or proj not in proj_set:
            continue
        if not (f["name"].startswith(".env") or f["name"] == "env.example"):
            continue
        if depth_from_project(f) > 2:
            continue
        for line in read_lines(f["abspath"]):
            if re.match(r"^\s*#", line):
                continue
            m = re.match(r"^([A-Z_]+(?:HOST|URL|API_URL))\s*=\s*['\"]*([^'\"\s]+)", line)
            if not m:
                continue
            var_name, value = m.group(1), m.group(2)
            # skip self-references and infrastructure (redis, mysql, fluent, etc.)
            if re.search(r"redis|mysql|postgres|fluent|localhost|127\.0\.0\.1", value):
                continue
            if re.match(r"^https?://accounts\.", value):  # keycloak/auth
                continue

            target = ""
            # try to extract port from URL value
            pm = re.search(r":(\d{4,5})", value)
            if pm and pm.group(1) in PORT_TO_SERVICE:
                target = PORT_TO_SERVICE[pm.group(1)]
            # if no port match, try hostname match (first match wins)
            if not target:
                for known_host, service in HOST_TO_SERVICE.items():
                    if re.search(known_host, value):
                        target = service
                        break
            # try to infer from variable name prefix (e.g. CATALOG_HOST -> catalog)
            if not target:
                for known in projects:
                    ku = _known_upper(known)
                    if var_name in (ku + "_HOST", ku + "_URL", ku + "_API_URL", ku + "_BASE_URL"):
                        target = known
                        break

            if target and target != proj:
                emit(proj, target, "api", "low", "api-calls")


# ---------- gateway-routes (gateway/proxy/router projects only) ----------
_GATEWAY_NAME_PATTERNS = ("*gateway*", "*proxy*", "*router*")


def _is_gateway(project):
    return any(fnmatch.fnmatchcase(project, p) for p in _GATEWAY_NAME_PATTERNS)


def rule_gateway_routes(files, projects):
    gateway_projects = {p for p in projects if _is_gateway(p)}
    for f in files:
        proj = project_of(f)
        if proj is None or proj not in gateway_projects:
            continue
        depth = depth_from_project(f)

        if f["name"] in (".env", ".env.example", "env.example") and depth <= 2:
            for line in read_lines(f["abspath"]):
                if re.match(r"^\s*#", line):
                    continue
                m = re.match(r"^([A-Z_]+_(?:HOST|URL|BASE_URL|API_URL))\s*=\s*['\"]*(.+)$", line)
                if not m:
                    continue
                var_name = m.group(1)
                value = m.group(2).replace('"', "").replace("'", "")

                pm = re.search(r":(\d{4,5})", value)
                if pm and pm.group(1) in PORT_TO_SERVICE:
                    target = PORT_TO_SERVICE[pm.group(1)]
                    if target != proj:
                        emit(proj, target, "api", "medium", "gateway-routes")

                for known in projects:
                    ku = _known_upper(known)
                    if var_name.startswith(ku + "_") or var_name in (ku + "HOST", ku + "URL"):
                        if known != proj:
                            emit(proj, known, "api", "medium", "gateway-routes")

        elif re.match(r"^nginx.*\.conf$", f["name"]) and depth <= 4:
            for line in read_lines(f["abspath"]):
                m = re.search(r"proxy_pass\s+http://([a-zA-Z0-9_-]+):(\d+)", line)
                if not m:
                    continue
                host, port = m.group(1), m.group(2)
                if port in PORT_TO_SERVICE:
                    target = PORT_TO_SERVICE[port]
                    if target != proj:
                        emit(proj, target, "api", "medium", "gateway-routes")
                for known in projects:
                    if (host == known or host == known + "-service") and known != proj:
                        emit(proj, known, "api", "medium", "gateway-routes")

        elif (re.match(r"^apisix.*\.ya?ml$", f["name"]) or re.match(r"^routes.*\.yml$", f["name"])) and depth <= 4:
            for line in read_lines(f["abspath"]):
                m = re.search(r"upstream.*:\s*http://([a-zA-Z0-9_-]+):(\d+)", line)
                if not m:
                    continue
                port = m.group(2)
                if port in PORT_TO_SERVICE:
                    target = PORT_TO_SERVICE[port]
                    if target != proj:
                        emit(proj, target, "api", "medium", "gateway-routes")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: walk.py <workspace>\n")
        sys.exit(1)
    workspace = sys.argv[1]
    files, projects = collect(workspace)
    rule_docker_compose(files)
    rule_shared_db(files, projects)
    rule_api_calls(files, projects)
    rule_gateway_routes(files, projects)
    # shared-packages added in a later task


if __name__ == "__main__":
    main()
