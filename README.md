# ignition

Everything here is executed by machines, not read as documentation:
shell and Python payloads with their own tests and CI.

## Layout

```
scripts/
  setup.sh            the entry point — lane dispatcher, --help is the map
  setup/              one module per lane: core, common, rc, cli, bin,
                      uv, node_opencode, expose, download, android, java,
                      camofox, moli, lightpanda, llm-wiki, join, join-repl,
                      profile-muse, profile-repl, doctor, fix, cleanup
  tour.py / tour.sh   the tour engine: round-robin workspace visits with
                      per-stop verdicts and a failure-streak breaker
  replit/
    dotreplit.py      guarded .replit editor: schema + fleet-rule checks,
                      span-scoped edits, backup before every mutation
    libpool.sh        shared-library pool for box-local binaries
    resolve-libs.sh   LD_LIBRARY_PATH closure resolution
    generate-closure.sh, probe-tailnet-peers.sh, join-lifecycle-test.sh,
    start-replit-chromium.sh
  muse/
    ts_proxy_connect.py
  socks5-probe.py     SOCKS5 reachability probe
tests/
  tool-setup.sh       per-lane install test: install into an isolated
                      root, then the lane's own --doctor line must pass
  tomlkit-provision.sh  fresh-box case: setup provisions its own toml
                      python, the REPLIT_BASHRC pin lands, idempotent
  camofox_e2e.sh, camofox_mcp_check.sh, mcp_stdio_test.py
.github/workflows/ci.yml
                      change-scoped lanes: payload syntax + compile,
                      XDG-absent smoke, tomlkit provisioning, per-tool
                      install matrix (ubuntu / macos / windows)
```

## How to use

On a fresh Replit workspace (or a Muse VM), clone and run the lanes you
need — setup is idempotent, re-runs converge:

```bash
git clone https://github.com/skynight137/ignition
cd ignition

# Replit box: core stack + Camoufox + Tailscale join + workflows
bash scripts/setup.sh --machine repl --all
bash scripts/setup.sh --machine repl --tailscale --join --workflow

# Muse VM: join stack as the unprivileged service user
bash scripts/setup.sh --machine muse --user runner --tailscale --join

# A single tool lane, e.g. uv or node
bash scripts/setup.sh --uv
bash scripts/setup.sh --node

# Health of the local stack
bash scripts/setup.sh --doctor
```

Tour engine (run by the box's own workflow once installed):

```bash
bash scripts/tour.sh --browser camofox --machine repl
```

Guarded `.replit` edits — never edit the file with sed; the platform
rejects a malformed file and drops the workspace into recovery mode:

```bash
python3 scripts/replit/dotreplit.py check .replit --role leader
python3 scripts/replit/dotreplit.py set-env .replit KEY VALUE
python3 scripts/replit/dotreplit.py add-port .replit 8081
```

## Tests

```bash
# payload syntax (what CI runs on every change)
find scripts tests -name '*.sh' -exec bash -n {} \;
python3 -m py_compile scripts/*.py scripts/replit/*.py scripts/muse/*.py

# one install lane, isolated root, doctor-verified
SETUP_ROOT=/tmp/ws bash tests/tool-setup.sh --uv "uv:"

# fresh-box toml provisioning
SETUP_ROOT=/tmp/ws-tomlkit bash tests/tomlkit-provision.sh
```

Secrets never live in this repo. Values a lane needs (a Tailscale auth
key, an API token) are supplied by the operator on the box — in the
workspace `.replit` userenv, a platform secret, or a local `.env` —
and setup stops short of using a lane while its value is empty.
