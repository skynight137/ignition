# hooks/

Versioned source of truth for the muse-hop stack watchdog hook.

## Mirror relationship

The hook runner executes **only** the live copies under `~/hooks/`:

- live script: `~/hooks/scripts/muse-hop-stack-watch.sh`
- live definition: `~/hooks/definitions/muse-hop-stack-watch.json`

The runner rejects scripts outside `~/hooks/scripts/`, so the copies in
this directory are **not** executed from here. They are the versioned
source; sync is one-way, repo -> live, via `hooks/install.sh`:

```sh
bash hooks/install.sh
```

The installer is idempotent and safe to re-run. A live copy that differs
from the repo version is overwritten with the repo version and the
overwrite is logged by filename. Never edit the live copies by hand —
change the repo copy, then run the installer.

## What the hook guards

`muse-hop-stack-watch` polls `~/workspace/tests/stack-health.sh` every
90 seconds (script timeout 600s) and stays silent while the stack is
healthy. When any probe prints a `FAIL` line it wakes an agent (at most
once per 15-minute cooldown while continuously down) whose job is to
restore the stack.

The stack it guards is the muse-hop join stack built by this repo:

```sh
bash scripts/setup.sh --machine muse --user runner --tailscale --join
```

The restore itself runs that same `setup.sh` — it lives in this repo,
and the hook's wake prompt (in the definition) tells the woken agent to
run it, then re-run `stack-health.sh` to confirm the heal.
