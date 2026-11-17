# toolskit

Setup and machining repo for the fleet and Muse VMs. One entry point provisions a box: toolchains, Tailscale join, shell rc, `.replit` workflows, beacon loop, and the tour engine.

## Explain

`toolskit` turns a fresh box into a working fleet node. Two machine kinds, one command surface:

- **Replit workspace** (`--machine repl`) — full stack: uv, Node/opencode, Java/Android, download tools, cloudflared, Tailscale join, Camoufox, Lightpanda, Moli, Tor, Hermes Chromium, llm-wiki, plus the beacon loop and watchdog.
- **Muse VM** (`--machine muse`) — the join stack: sshd, Tailscale binaries, reverse-tunnel loop, Termix user units, run as an unprivileged service user (`--user runner`).

`scripts/setup.sh` is the only entry. It detects the machine (`REPL_HOME` set → repl, otherwise muse) or takes `--machine muse|repl`, then hands off to `scripts/setup/profile-repl.sh` or `scripts/setup/profile-muse.sh`. Setup is idempotent — re-runs converge instead of duplicating work. Secrets never live in this repo.

Layout:

```
scripts/
  setup.sh            entry — lane dispatcher, --machine muse|repl
  setup/              one module per lane: core, common, rc, cli, bin,
                      uv, node_opencode, expose, download, android, java,
                      camofox, moli, lightpanda, llm-wiki, join, join-repl,
                      profile-muse, profile-repl, doctor, fix, cleanup,
                      tor, hermes_chromium, ui_menu, zsh, root
  tour.py / tour.sh   tour engine: round-robin workspace visits, per-stop
                      verdicts, failure-streak breaker
  replit/
    dotreplit.py      guarded .replit editor (schema + fleet-rule checks,
                      backup before every mutation)
    beacon-loop.sh    node-stats beacon, every 300 s (BEACON_INTERVAL_S)
    beacon-watchdog.sh  supervisor: restarts the beacon loop when dead
                      or stale (check every 60 s)
    tsbeacon.sh, wake-push.py, crash-shim-loop.sh, crash-shim.py,
    libpool.sh, resolve-libs.sh, generate-closure.sh,
    probe-tailnet-peers.sh, join-lifecycle-test.sh,
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

## How it Works

1. **Dispatch.** `scripts/setup.sh` resolves `--machine` (or auto-detects), then `exec`s the matching profile. The repl profile sources every lane in `scripts/setup/` and `scripts/setup/cli.sh` runs `main` — on a TTY a bare run opens the interactive pick-menu; explicit targets skip the menu.
2. **Lanes.** Each lane installs one thing and verifies itself: pinned versions, checksum-verified downloads (no `curl|bash` installers), `core.sh` logging/verify primitives shared by both profiles. `doctor.sh` is the read-only toolchain self-check.
3. **Join.** The join lane (`scripts/setup/join.sh` engine + `join-repl.sh` / `profile-muse.sh`) installs the sshd + Tailscale stack, joins the tailnet with the operator-supplied auth key, then starts the beacon loop and watchdog detached (deduped by pidfile, never fails the join). The muse profile records the service user in `.env` as `RS_SSH_USER` and re-asserts the `/root/.ssh` pointer, logind, and root lingering on every start so units auto-start after a redeploy.
4. **Beacon.** `scripts/replit/beacon-loop.sh` wakes `tsbeacon.sh` every `BEACON_INTERVAL_S` (default 300 s) to post node stats; on the first post after a (re)start it also runs `wake-push.py` once (buffered beacon + log tails to the payload store). `beacon-watchdog.sh` checks every 60 s and restarts the loop when it is dead or alive-but-stale. A workspace stop kills both; the next boot's join starts them again.
5. **`.replit` edits.** Never edit `.replit` with sed — the platform rejects a malformed file and drops the workspace into recovery mode. `scripts/replit/dotreplit.py` parses first, edits only the target section's span, re-parses, re-validates, and restores the backup (`FILE.bak-dtr-<epoch>`) if the dotted key set changed outside the intended op. Fleet rule: nothing may come after `[userenv.shared]`.
6. **Tour.** `scripts/tour.sh` is a launcher only (env assembly: nix `LD_LIBRARY_PATH` for the tour venv's greenlet, Python resolution); all logic lives in `scripts/tour.py`. A leader workflow runs it round-robin over its members with per-stop verdicts; 3 consecutive failed stops trigger the breaker.
7. **Tests.** CI runs payload syntax + compile checks, an XDG-absent smoke test, tomlkit provisioning, and the per-tool install matrix on every change.

## What's to Prepare

- A fresh Replit workspace, or a fresh Muse VM. Bash >= 4 (`bash --version`).
- `git` — clone the repo on the target box.
- A Tailscale auth key for the tailnet. The operator creates the stack `.env` (mode `0600`) with `TAILSCALE_AUTH_KEY=<key>`; setup writes a template and stops short of the join while the key is empty. The key never goes in the repo.
- For a Muse VM join: the peer that holds the reverse forwards (set via `--peer <name>` or `RS_PEER`; prefer its MagicDNS name — tailnet IPs are ephemeral and must never be pinned). The peer's public key goes in `$SSHDIR/join-tailnet/authorized_keys`; this VM's client pubkey (`$SSHDIR/id_ed25519.pub`, printed at the end of setup) goes on the peer's sshd.
- For a Replit box: `SETUP_ROOT` resolves once (`root.sh`) — explicit `$SETUP_ROOT`, recorded root, or platform workspace; an unresolvable root stops the run before anything installs.
- Contact: `skynight137@users.noreply.github.com`.

## Quick Start

```bash
git clone https://github.com/skynight137/toolskit
cd toolskit

# Muse VM: join stack as the unprivileged service user
bash scripts/setup.sh --machine muse --user runner --tailscale --join

# Muse VM: single phases, or read-only status
bash scripts/setup.sh --machine muse --sshd
bash scripts/setup.sh --machine muse --tailscale
bash scripts/setup.sh --machine muse --tor
bash scripts/setup.sh --machine muse --verify

# Replit box: bare run opens the interactive pick-menu on a TTY
bash scripts/setup.sh --machine repl

# Replit box: full stack, or Tailscale join + workflows
bash scripts/setup.sh --machine repl --all
bash scripts/setup.sh --machine repl --tailscale --join --workflow

# Replit box: a single lane, e.g. uv or node
bash scripts/setup.sh --machine repl --uv
bash scripts/setup.sh --machine repl --node

# Health of the local stack (doctor lane, read-only)
bash scripts/setup.sh --doctor

# Guarded .replit edits
python3 scripts/replit/dotreplit.py check .replit --role leader
python3 scripts/replit/dotreplit.py set-env .replit KEY VALUE
python3 scripts/replit/dotreplit.py add-port .replit 8081

# Tour engine (run by the box's own workflow once installed)
bash scripts/tour.sh --browser camofox --machine repl
```

Tests (what CI runs on every change):

```bash
find scripts tests -name '*.sh' -exec bash -n {} \;
python3 -m py_compile scripts/*.py scripts/replit/*.py scripts/muse/*.py
SETUP_ROOT=/tmp/ws bash tests/tool-setup.sh --uv "uv:"
SETUP_ROOT=/tmp/ws-tomlkit bash tests/tomlkit-provision.sh
```

## Example live

Operator brings up a fresh Muse VM as a join target, then a Replit box:

```bash
# 1. On the fresh Muse VM: clone, create the stack .env with the auth key
git clone https://github.com/skynight137/toolskit
cd toolskit
printf 'TAILSCALE_AUTH_KEY=<key>\n' > ~/.ssh/.env && chmod 600 ~/.ssh/.env

# 2. Install the join stack as runner and join the tailnet
bash scripts/setup.sh --machine muse --user runner --tailscale --join
#    -> prints the client pubkey; add it to the peer's sshd authorized_keys

# 3. Verify the stack is up (read-only)
bash scripts/setup.sh --machine muse --verify
#    -> sshd listening, tailscaled up, node joined, reverse loop running

# 4. On a fresh Replit workspace: clone and run the pick-menu
git clone https://github.com/skynight137/toolskit
cd toolskit
bash scripts/setup.sh --machine repl
#    -> pick the lanes in the menu; the join lane starts the beacon loop
#       and watchdog detached when tailscaled is up

# 5. Confirm the box is reporting, then guard a .replit change
python3 scripts/replit/dotreplit.py check .replit --role leader
python3 scripts/replit/dotreplit.py set-env .replit TAILSCALE_AUTH_KEY <key>
#    -> check passes, edit lands, backup FILE.bak-dtr-<epoch> beside .replit
```
