# Recorder deployment — the live Azure VM

**Why this file exists:** the recorder runs on a cloud VM that nothing in this
repo can rebuild from scratch without these details. This file was recreated on
2026-08-16 after it went missing from the working copy, which cost a session
re-asking for the login. Keep it up to date — see the note at the bottom.

Everything here is infrastructure detail, not a secret. The private key is
**not** in this repo and must never be committed.

---

## The VM

Read off the Azure Portal (Resource Manager → Recent resources), 2026-08-16:

| thing | value |
|---|---|
| Subscription | Azure for Students |
| Account | `nagaraj14567@outlook.com` |
| Resource group | `wimb` |
| Region | **UAE North** — not India. It is the closest region that subscription allows |
| VM size | `Standard_B2ats_v2` |

Resources in the `wimb` group, all named after the VM:

| resource | type |
|---|---|
| `wimb-recorder` | Virtual machine |
| `wimb-recorder-vnet` | Virtual network |
| `wimb-recorder-nsg` | Network security group |
| `wimb-recorder-ip` | Public IP address |
| `wimb-recorder184` | Network interface |
| `wimb-recorder_DataDisk_0` | Disk — where the archive is written |

**Azure for Students was chosen because it needs no credit card.** Oracle
Cloud's Always Free tier was tried first and rejected for exactly that reason.

## Connecting

Last known public IP: **`40.123.233.174`**

> This is the address in the laptop's `~/.ssh/known_hosts`. If `wimb-recorder-ip`
> is a *dynamic* public IP, it changes every time the VM is deallocated and
> restarted, so treat this as a hint, not a fact. The Portal's VM Overview page
> always shows the current one.

Key on the laptop: `~/.ssh/id_ed25519` (public half is commented
`wimb-recorder` — that is just a label, it is **not** the login name).

**Linux username: `azureuser`** (Azure's own default — confirmed via Portal →
VM `wimb-recorder` → Connect → Native SSH, 2026-08-16). `wimb-recorder` is the
Azure *resource* name and does **not** work as a login — that mix-up cost a
round trip once already, don't repeat it.

```bash
ssh -i ~/.ssh/id_ed25519 azureuser@40.123.233.174
```

Confirmed from the Portal Overview page the same day: OS **Ubuntu 24.04**,
status **Running**, size `Standard_B2ats_v2` (2 vCPU, 1 GiB memory), created
2026-08-09 09:49 UTC.

## Checking it is alive

The single most important check. Historical feed data cannot be collected
retroactively — every hour the recorder is down is evaluation data permanently
lost (CLAUDE.md §7, "Phase 0 is the only irreversible deadline").

In the Portal, the VM Overview page shows **Status**. `Running` is fine;
`Stopped (deallocated)` means recording has stopped.

Over SSH:

```bash
systemctl status wimb-recorder
```

```bash
df -h        # the archive disk filling up would also stop collection
```

## Where the data lives on the VM

Same layout as the `DATA_ROOT` convention in CLAUDE.md §9:

```
raw/<YYYY-MM-DD>/vp-<timestamp>.pb.gz    the immutable frames
manifest/<YYYY-MM-DD>.jsonl              one line per fetch attempt
```

Roughly **240 MB per full day** (~8,640 frames at one every 10s).

## Pulling the archive down to the laptop

Target on the laptop is `C:\Users\nagga\Desktop\DATA FOR WIMB` — deliberately
outside the repo, so it can never be caught in a repo clean.

```bash
rsync -av --progress -e "ssh -i ~/.ssh/id_ed25519" <USERNAME>@40.123.233.174:~/raw/ "/c/Users/nagga/Desktop/DATA FOR WIMB/raw/"
```

`rsync` is the right tool because it only transfers what is missing, so it is
safe and cheap to re-run. If Git Bash has no `rsync`, `scp -r` works but
re-copies everything.

After pulling, load the new days into Postgres — the loader is idempotent and
only adds frames it has not seen:

```bash
npm run load-realtime
```

## Keeping this file honest

If you change the VM, the key, the username or the paths, update this file in
the same sitting. The project is worked on with several different AI assistants
and none of them can read your memory — this file is the handover.
