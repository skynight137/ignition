#!/usr/bin/env python3
"""dotreplit.py — guarded reader/editor for .replit files.

Why this exists: on a live box, .replit is owned by pid2's schema-validated
CRDT room and pid1's protobuf DotReplit service (see
skills/replit/references/dotreplit-handler.md). A file the schema rejects
flips the workspace shell into recovery mode, and hand-rolled text surgery
has already eaten a fleet [userenv.shared] section once (2026-11-11). So
programmatic edits go through this helper, never through regex/segment
edits:

  check  FILE [--role leader|commander|member]   validate + fleet rules
  envlen FILE KEY                                presence + length, no value
  set-env FILE KEY VALUE | del-env FILE KEY      [userenv.shared] ops
  set-waitforport FILE WORKFLOW PORT             one workflow task's port
  add-port FILE PORT | del-port FILE PORT        identity [[ports]] pair
  add-workflow FILE SNIPPET.toml                 append one workflow block

Every mutating op: parses first, edits only the target section's span,
re-parses, re-validates, and proves the dotted key set is unchanged
outside the intended op — otherwise it restores the backup and fails.
Backups land beside the file as FILE.bak-dtr-<epoch>.

Exit codes: 0 ok · 2 schema violation · 3 fleet-rule violation ·
4 parse failure · 5 edit/verify failure.
Stdlib only.
"""
import re
import shutil
import sys
import time

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11 fallback if tomli is around
    import tomli as tomllib

SECRET_HINTS = ("KEY", "PAT", "TOKEN", "SECRET", "PASSWORD")


# ---------- model ----------

def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def keyset(doc, prefix=""):
    out = set()
    if isinstance(doc, dict):
        for k, v in doc.items():
            p = f"{prefix}.{k}" if prefix else k
            out.add(p)
            out |= keyset(v, p)
    elif isinstance(doc, list):
        for i, v in enumerate(doc):
            out |= keyset(v, f"{prefix}[{i}]")
    return out


def schema_errors(doc):
    """The pid2-shaped checks: types the DotReplit schema enforces on the
    fields the fleet touches. Unknown fields are not judged here."""
    errs = []
    for i, p in enumerate(doc.get("ports", [])):
        for f in ("localPort", "externalPort"):
            v = p.get(f)
            if not isinstance(v, int) or not (1 <= v <= 65535):
                errs.append(f"ports[{i}].{f} must be int 1..65535, got {v!r}")
    ue = doc.get("userenv", {}).get("shared", {})
    if not isinstance(ue, dict):
        errs.append("userenv.shared must be a table")
    else:
        for k, v in ue.items():
            if not isinstance(v, str):
                errs.append(f"userenv.shared.{k} must be a string, got {type(v).__name__}")
    wf_root = doc.get("workflows", {})
    for w in wf_root.get("workflow", []):
        if not isinstance(w.get("name"), str):
            errs.append("workflows.workflow entry missing string 'name'")
        for t in w.get("tasks", []):
            wp = t.get("waitForPort")
            if wp is not None and (not isinstance(wp, int) or not (1 <= wp <= 65535)):
                errs.append(
                    f"workflow {w.get('name')!r} task {t.get('task')!r}: "
                    f"waitForPort must be int 1..65535, got {wp!r}")
            args = t.get("args")
            ok_args = isinstance(args, str) or (
                isinstance(args, list) and all(isinstance(a, str) for a in args))
            if args is not None and not ok_args:
                errs.append(f"workflow {w.get('name')!r}: task args must be a string "
                            "or a list of strings")
    return errs


def fleet_errors(doc, text, role, template=False):
    errs, warns = [], []
    for i, p in enumerate(doc.get("ports", [])):
        if p.get("localPort") != p.get("externalPort"):
            errs.append(
                f"ports[{i}]: localPort {p.get('localPort')} != externalPort "
                f"{p.get('externalPort')} (identity rule)")
    if role in ("leader", "commander"):
        ue = doc.get("userenv", {}).get("shared", {})
        for k in ("SKILLS_PAT", "TAILSCALE_AUTH_KEY"):
            if k not in ue:
                errs.append(f"[userenv.shared] missing {k} (two-vars rule)")
            elif not ue[k] and not template:
                errs.append(f"[userenv.shared] {k} is empty on a configured box")
    heads = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("[")]
    if "[userenv.shared]" in heads:
        after = heads[heads.index("[userenv.shared]") + 1:]
        if after:
            warns.append(f"sections after [userenv.shared]: {after} "
                         "(fleet convention: userenv.shared last; platform "
                         "serializers may differ — warning only)")
    for w in doc.get("workflows", {}).get("workflow", []):
        if w.get("name") == "launch-camofox":
            for t in w.get("tasks", []):
                if t.get("waitForPort") not in (None, 9377):
                    warns.append(
                        f"launch-camofox waitForPort is {t.get('waitForPort')}, "
                        "fleet camofox binds 9377")
    return errs, warns


# ---------- text spans ----------

HEADER_RE = re.compile(r"^\s*\[.*\]\s*$")


def spans(lines):
    """Yield (header_line_or_None, start_idx, end_idx) per section."""
    idx = [i for i, ln in enumerate(lines) if HEADER_RE.match(ln)]
    if not idx or idx[0] != 0:
        yield (None, 0, idx[0] if idx else len(lines))
    for n, i in enumerate(idx):
        end = idx[n + 1] if n + 1 < len(idx) else len(lines)
        yield (lines[i].strip(), i, end)


def find_span(lines, header):
    for h, s, e in spans(lines):
        if h == header:
            return s, e
    return None


def toml_str(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ---------- guarded edit ----------

def guarded_edit(path, mutate, intended_removed_prefixes=()):
    text = open(path).read()
    before = load(path)
    before_keys = keyset(before)
    lines = text.splitlines(keepends=True)
    new_lines = mutate(lines)
    if new_lines is None:
        print("edit aborted by op (target not found)", file=sys.stderr)
        return 5
    backup = f"{path}.bak-dtr-{int(time.time())}"
    shutil.copy2(path, backup)
    with open(path, "w") as fh:
        fh.writelines(new_lines)
    try:
        after = load(path)
        errs = schema_errors(after)
        if errs:
            raise ValueError("schema: " + "; ".join(errs))
        lost = {k for k in before_keys - keyset(after)
                if not any(k == p or k.startswith(p + ".") or k.startswith(p + "[")
                           for p in intended_removed_prefixes)}
        if lost:
            raise ValueError(f"key loss outside intended op: {sorted(lost)}")
    except Exception as exc:
        shutil.copy2(backup, path)
        print(f"VERIFY FAILED, restored {backup}: {exc}", file=sys.stderr)
        return 5
    print(f"ok (backup {backup})")
    return 0


# ---------- ops ----------

def op_check(path, role, template=False):
    try:
        doc = load(path)
    except Exception as exc:
        print(f"PARSE FAILURE: {exc}")
        return 4
    errs = schema_errors(doc)
    if errs:
        for e in errs:
            print(f"SCHEMA: {e}")
        return 2
    ferrs, warns = fleet_errors(doc, open(path).read(), role, template)
    for w in warns:
        print(f"WARN: {w}")
    if ferrs:
        for e in ferrs:
            print(f"FLEET: {e}")
        return 3
    print("ok: schema + fleet rules pass")
    return 0


def op_envlen(path, key):
    doc = load(path)
    ue = doc.get("userenv", {}).get("shared", {})
    if key not in ue:
        print(f"{key}: ABSENT")
        return 3
    print(f"{key}: present, len {len(ue[key])}")
    return 0


def _env_span(lines):
    span = find_span(lines, "[userenv.shared]")
    if span is None:
        print("[userenv.shared] header not found", file=sys.stderr)
    return span


def op_set_env(path, key, value):
    def mutate(lines):
        span = _env_span(lines)
        if span is None:
            return None
        s, e = span
        kv = re.compile(rf"^\s*{re.escape(key)}\s*=")
        for i in range(s + 1, e):
            if kv.match(lines[i]):
                lines[i] = f"{key} = {toml_str(value)}\n"
                return lines
        lines.insert(e, f"{key} = {toml_str(value)}\n")
        return lines
    return guarded_edit(path, mutate)


def op_del_env(path, key):
    def mutate(lines):
        span = _env_span(lines)
        if span is None:
            return None
        s, e = span
        kv = re.compile(rf"^\s*{re.escape(key)}\s*=")
        for i in range(s + 1, e):
            if kv.match(lines[i]):
                del lines[i]
                return lines
        return None
    return guarded_edit(path, mutate, intended_removed_prefixes=(f"userenv.shared.{key}",))


def op_set_waitforport(path, workflow, port):
    port = int(port)

    def mutate(lines):
        # a workflow's extent runs from its [[workflows.workflow]] header to
        # the next [[workflows.workflow]] header (its [[...tasks]] and
        # [metadata] subsections live inside that extent)
        name_re = re.compile(rf'^\s*name\s*=\s*"{re.escape(workflow)}"')
        all_spans = list(spans(lines))
        blocks = [(s, e) for h, s, e in all_spans
                  if h and h.startswith("[[workflows.workflow]]")]
        for n, (s, e) in enumerate(blocks):
            head_end = blocks[n + 1][0] if n + 1 < len(blocks) else len(lines)
            for h2, s2, _e2 in all_spans:
                if s2 > s and not h2.strip("[]").startswith("workflows.workflow"):
                    head_end = min(head_end, s2)
                    break
            # the workflow's own name sits before its first subsection header
            sub = next((i for i in range(s + 1, head_end)
                        if HEADER_RE.match(lines[i])), head_end)
            if not any(name_re.match(lines[i]) for i in range(s + 1, sub)):
                continue
            for i in range(s + 1, head_end):
                if re.match(r"^\s*waitForPort\s*=", lines[i]):
                    lines[i] = f"waitForPort = {port}\n"
                    return lines
            return None  # workflow found, no waitForPort: refuse to invent one
        return None
    return guarded_edit(path, mutate)


def _port_blocks(lines):
    return [(s, e) for h, s, e in spans(lines) if h == "[[ports]]"]


def op_add_port(path, port):
    port = int(port)
    doc = load(path)
    if any(p.get("localPort") == port for p in doc.get("ports", [])):
        print(f"port {port} already declared")
        return 0
    block = f"[[ports]]\nlocalPort = {port}\nexternalPort = {port}\n\n"

    def mutate(lines):
        blocks = _port_blocks(lines)
        if blocks:
            lines.insert(blocks[-1][1], block)
            return lines
        span = find_span(lines, "[userenv]")
        if span is None:
            return None
        lines.insert(span[0], block)
        return lines
    return guarded_edit(path, mutate)


def op_del_port(path, port):
    port = int(port)

    def mutate(lines):
        for s, e in _port_blocks(lines):
            body = "".join(lines[s:e])
            if re.search(rf"localPort\s*=\s*{port}\b", body):
                del lines[s:e]
                return lines
        return None
    return guarded_edit(path, mutate, intended_removed_prefixes=("ports",))


def op_add_workflow(path, snippet_path):
    snippet = open(snippet_path).read()
    try:
        frag = tomllib.loads(snippet)
    except Exception as exc:
        print(f"snippet parse failure: {exc}", file=sys.stderr)
        return 4
    wfs = frag.get("workflows", {}).get("workflow", [])
    if len(wfs) != 1 or not isinstance(wfs[0].get("name"), str):
        print("snippet must contain exactly one [[workflows.workflow]] with a name",
              file=sys.stderr)
        return 4
    name = wfs[0]["name"]
    doc = load(path)
    if any(w.get("name") == name
           for w in doc.get("workflows", {}).get("workflow", [])):
        print(f"workflow {name!r} already exists", file=sys.stderr)
        return 3
    errs = schema_errors(frag)
    if errs:
        for e in errs:
            print(f"SCHEMA: {e}")
        return 2
    block = snippet.strip("\n") + "\n\n"

    def mutate(lines):
        span = find_span(lines, "[userenv]")
        if span is None:
            return None
        lines.insert(span[0], block)
        return lines
    return guarded_edit(path, mutate)


# ---------- main ----------

def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd, path = argv[1], argv[2]
    if cmd == "check":
        role = None
        if "--role" in argv:
            role = argv[argv.index("--role") + 1]
        return op_check(path, role, template="--template" in argv)
    if cmd == "envlen":
        return op_envlen(path, argv[3])
    if cmd == "set-env":
        return op_set_env(path, argv[3], argv[4])
    if cmd == "del-env":
        return op_del_env(path, argv[3])
    if cmd == "set-waitforport":
        return op_set_waitforport(path, argv[3], argv[4])
    if cmd == "add-port":
        return op_add_port(path, argv[3])
    if cmd == "add-workflow":
        return op_add_workflow(path, argv[3])
    if cmd == "del-port":
        return op_del_port(path, argv[3])
    print(f"unknown command {cmd!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
