# Flutter setup — the light path, for a 16 GB laptop running Docker

**Status: installed and running on a real phone (2026-08-20).** Flutter
3.47.1 stable, Android SDK (platform 34 + 36, build-tools 28.0.3 + 34.0.0),
OpenJDK 17, VS Code extensions, `flutter doctor` clean. Phone connects over
**home WiFi** with no cable needed day to day — the one-time setup for
that is §5. What actually happened, versus what was planned below, in §0.
Two real operational traps hit while running `flutter run` from a script
are written up in §9 and §10 — worth reading before automating this
again, for a human or another AI.

---

## 0. What actually got installed, and two things worth knowing

Followed the plan below with two real deviations:

1. **Flutter was installed via `git clone` of the stable branch**, not a
   zip download — one of Flutter's two official install methods, and
   the one that makes future `flutter upgrade` a plain `git pull`.
   `C:\src\flutter`, added to the user `PATH`.

2. **The SDK platform version needed correcting.** The plan below (and
   most guides) say `platforms;android-34`. This Flutter build
   (3.47.1) actually asked for **`platforms;android-36`** and, oddly,
   the much older **`build-tools;28.0.3`** alongside `34.0.0` — found by
   installing 34 first, running `flutter doctor`, and reading what it
   actually asked for rather than assuming the version in a guide is
   still current. Worth re-checking with `flutter doctor -v` if this is
   ever redone against a newer Flutter release.

Also installed: **Microsoft OpenJDK 17** (`sdkmanager` needs Java and
none was present — Android's current command-line tools require Java 17+)
and the **Flutter + Dart VS Code extensions**.

**`flutter doctor` result:**

```
[√] Flutter (Channel stable, 3.47.1)
[√] Windows Version
[√] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
[√] Chrome - develop for the web
[X] Visual Studio - develop Windows apps      <- deliberately skipped, see below
[√] Connected device (3 available)
[√] Network resources
```

**The `[X] Visual Studio` line is not a problem** — it is for building
Windows *desktop* apps, which this project was never going to do. Building
it would mean the multi-GB "Desktop development with C++" workload,
exactly the disk/RAM cost §1 below explains how to avoid. Android via a
physical phone needs none of it.

**One cleanup worth knowing about:** the Android platform-tools package
(`adb`, `fastboot`) installs via `winget`, which places it at a path winget
chooses. It had to be moved into the standard SDK layout
(`C:\Android\platform-tools`, matching what `$ANDROID_HOME` expects) and
one stale `PATH` entry pointing at the old winget location had to be
cleaned up afterward. If `adb` or `flutter doctor`'s Android check ever
stops finding a tool, check for exactly this — a PATH entry surviving a
manual move.

**A phone is connected and running the app, wirelessly.** §5 below is the
full sequence used: USB once to authorize + enable wireless debugging,
then never again. §7 explains why WiFi was chosen over both `adb reverse`
(works, but needs the cable every session) and ngrok (rejected — see the
box in §7, it would have put the dev database on the public internet).

---

Phase 6 needs Flutter. This is how to install it on **this** machine
without the app work fighting the database work for memory.

Measured on this laptop (i7-12700H, 14 cores / 20 threads, 16 GB RAM,
~95 GB free): CPU and disk are comfortable. **RAM is the only real
constraint**, so every choice below is made to protect it.

---

## 1. Why not just install Android Studio

The obvious route — Android Studio plus its emulator — does work, but on
16 GB it leaves nothing over:

| what | roughly |
|---|---|
| Windows itself | 3–4 GB |
| Docker / WSL2 (already capped at 5 GB in `~/.wslconfig`) | 2–5 GB |
| Android Studio + Gradle | 3–4 GB |
| Android emulator | 2–3 GB |

That totals 13–16 GB before a browser is open. The machine will swap and
everything feels broken, which reads as "my laptop is too slow" when it is
actually just full.

**Three swaps fix it, and each one is independently worth doing:**

1. **A real phone over USB instead of the emulator.** Saves 2–3 GB *and*
   is genuinely faster than an emulated device. Hot reload works exactly
   the same.
2. **VS Code instead of Android Studio.** Flutter needs the Android
   **SDK**, not the IDE. VS Code is already installed here and uses about
   400 MB against Android Studio's 1.5–2 GB.
3. **Stop Docker while building screens.** Laying out UI does not need the
   API. `docker compose up -d` takes seconds when real data is wanted.

That lands around 8–10 GB in use instead of 16, with the strong CPU free
to do Gradle builds quickly.

> If the Android Studio device manager or layout inspector is genuinely
> wanted later, it can be installed alongside all this. The rule is just:
> **pick any two of {Android Studio, emulator, Docker}**, never all three.

---

## 2. Install Flutter (on Windows, not WSL)

CLAUDE.md §6 is specific about this: **Flutter installs on Windows proper,
not inside WSL.** Building Android apps from inside WSL means fighting USB
passthrough for no benefit.

1. Download the Flutter SDK for Windows from
   <https://docs.flutter.dev/get-started/install/windows>
2. Extract to a path with **no spaces** — `C:\src\flutter` is the
   conventional choice. (Not `C:\Program Files\`; the space breaks some
   Dart tooling.)
3. Add `C:\src\flutter\bin` to the Windows `Path` environment variable.
4. Open a **new** terminal and check:

```bash
flutter --version
```

---

## 3. Install the Android SDK without Android Studio

Google ships the SDK tools separately from the IDE.

1. Download **"Command line tools only"** for Windows from the bottom of
   <https://developer.android.com/studio>
2. Extract so the final layout is exactly:
   `C:\Android\cmdline-tools\latest\bin\sdkmanager.bat`
   (the `latest` folder name matters — `sdkmanager` refuses to run without
   it)
3. Set `ANDROID_HOME` to `C:\Android` and add
   `C:\Android\cmdline-tools\latest\bin` and `C:\Android\platform-tools`
   to `Path`.
4. Install the pieces Flutter actually needs:

```bash
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
```

```bash
sdkmanager --licenses
```

Roughly 10 GB of disk. Skip every `system-images;…` package — those are
emulator images, which is the thing being avoided.

---

## 4. VS Code

Install two extensions:

- **Flutter** (by Dart Code) — pulls in the Dart extension too
- **Dart** (comes with the above)

That is the whole IDE setup. Hot reload, breakpoints, and the widget
inspector all work from here.

---

## 5. The phone — one-time USB, then wireless forever

The end state wanted: **no cable needed for day-to-day work.** Getting
there needs the cable exactly once, because Android's wireless debugging
has to inherit trust from an already-authorized USB connection — there is
no way to establish that trust wirelessly from nothing (and that is a
deliberate security property, not a limitation to work around).

**Step 1 — unlock developer settings, once:**

1. Settings → About phone → tap **"Build number"** seven times.
2. Settings → Developer options → **USB debugging: on**.

**Step 2 — the one-time cable connection:**

3. Plug in with a cable that carries data (many charging-only cables
   don't — if `adb devices` sees nothing, try a different cable first).
4. The phone shows **"Allow USB debugging from this computer?"** — tap
   Allow. This is the actual security boundary: it creates a unique
   cryptographic key pairing between this specific laptop and this
   specific phone. No other computer has it, and no wireless step below
   can substitute for this tap.
5. Confirm the laptop sees it:

```bash
adb devices -l
```

   Should show `device` (not `unauthorized`, not `offline`).

**Step 3 — turn on wireless debugging while still plugged in:**

6. Find the phone's WiFi IP address (needed for step 7):

```bash
adb shell ip -f inet addr show wlan0
```

   Look for the `inet` line, e.g. `inet 10.3.7.164/23` → the IP is
   `10.3.7.164`.

7. Switch `adb` from USB to listening over the network, using the trust
   already established in step 4 — no separate pairing code needed:

```bash
adb tcpip 5555
```

8. Connect to it over WiFi:

```bash
adb connect 10.3.7.164:5555
```

9. **Now unplug the cable.** Confirm it survives without it:

```bash
adb devices -l
```

   Should still show the phone, now listed as `10.3.7.164:5555` instead
   of a USB serial number.

That connection lasts until the phone reboots or leaves the WiFi network.
If it ever drops, redo steps 6–8 (still no cable needed, since the phone
already trusts this laptop from step 4 — wireless debugging just needs to
be toggled back on in Developer options first if the phone was rebooted).

**Step 4 — run the app on it:**

```bash
cd app
flutter run -d 10.3.7.164:5555 --release
```

`--release` was used for the first real run mainly because it was the
mode reached for at the time, not from a tested comparison — plain
`flutter run` (debug mode) is the normal choice while actively developing,
since it's what gives hot reload. `--release` is what you'd use to see the
app run at its real speed. Worth trying both if build time ever matters —
untested here which one is actually faster to build on this machine.

---

## 6. Confirm everything

```bash
flutter doctor
```

Every line should be a tick except "Android Studio" and "Chrome", both of
which are fine to leave unresolved — Android Studio is deliberately not
installed, and Chrome only matters for Flutter web.

If Android licences complain, run `flutter doctor --android-licenses`.

---

## 7. The gotcha that will otherwise cost an hour

**A phone cannot reach `localhost:3000` on the laptop.** To the phone,
`localhost` is the phone. The API will simply appear dead, with a
connection-refused error that looks like the server is broken when it is
running perfectly.

**Chosen fix: the laptop's WiFi IP, with a scoped firewall rule.**

1. Find the laptop's WiFi address:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -eq "Wi-Fi" }
```

2. Open port 3000 to the **home network only** (needs an admin
   PowerShell — right-click Start → Terminal (Admin)):

```powershell
New-NetFirewallRule -DisplayName "WIMB API (dev, port 3000)" -Direction Inbound -Protocol TCP -LocalPort 3000 -Action Allow -Profile Private
```

   `-Profile Private` matters: it only opens the port on networks Windows
   has been told are trusted (home WiFi), never on Public profile networks
   like a café or airport. If the laptop's WiFi ever gets misclassified as
   Public, this rule simply won't apply there — fails safe, not open.

3. Point the app at `http://<laptop-wifi-ip>:3000` instead of `localhost`.

The API already binds to `0.0.0.0` (see `api/src/server.ts`), so no
server-side change is needed.

### Two alternatives considered and rejected — worth knowing why

**`adb reverse tcp:3000 tcp:3000`** (make the phone's own `localhost:3000`
tunnel to the laptop) genuinely works and needs no firewall rule at all.
It was the first approach used here. Rejected as the *permanent* answer
only because it needs a live USB connection to set up each time the app
restarts fresh — once wireless debugging was set up (§5), keeping WiFi
for the API too meant one consistent story instead of two. If wireless
debugging is ever unavailable, `adb reverse` is a perfectly good fallback
and does not need this section's firewall rule.

**ngrok** was asked about directly and turned down. It would give the API
a public internet address — reachable by anyone who found the URL, not
just this phone, and the API has no login on it. A permanent (non-rotating)
address needs ngrok's paid tier, so the free option would also break every
time the tunnel restarted. Right tool for showing a demo to someone
remote; wrong tool for a phone sitting on the same desk as the server.

---

## 8. Keeping memory sane day to day

- Building screens with no real data? Leave Docker stopped.
- Wiring up real data? `docker compose up -d`, then stop it after.
- Cap the Gradle heap in the app's `android/gradle.properties`:

```
org.gradle.jvmargs=-Xmx2g
```

  Gradle defaults to a much larger heap than this project needs, and on a
  16 GB machine that is memory taken from everything else.
- The WSL cap already lives in `~/.wslconfig` (5 GB, 6 processors). Drop
  `memory` to `3GB` while doing Flutter work if things feel tight — this
  project only runs Postgres in there, which is small. Apply with
  `wsl --shutdown`, then restart Docker Desktop.

---

## 9. Running `flutter run` from a script or an AI agent — two real traps

Both of these actually happened while getting the app running on the
phone. Neither is a Flutter problem — both are about how *any* long-running
build looks from outside when driven by a script instead of a human
watching a terminal.

### Trap 1: each new PowerShell process forgets the PATH just set

`[Environment]::SetEnvironmentVariable(..., "User")` writes to the
registry. A **brand new** terminal reads that on startup. But if something
(a script, an AI agent's tool calls) launches a **fresh PowerShell.exe
per command** rather than reusing one open session, none of those
processes inherit the change — each one starts from the *old* environment
that existed before `ANDROID_HOME` / `JAVA_HOME` / the new `PATH` entries
were set.

The fix used throughout this session: reload from the registry explicitly
at the top of every script/command that needs these tools, rather than
assuming a previous command's `$env:` changes carried over:

```powershell
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"
$env:JAVA_HOME = [Environment]::GetEnvironmentVariable("JAVA_HOME", "User")
$env:ANDROID_HOME = [Environment]::GetEnvironmentVariable("ANDROID_HOME", "User")
```

A **human** opening one real terminal window and working in it all session
does not hit this at all — it is specifically a symptom of automation
spawning a new process per command. Worth knowing so a "command not
found" error for a tool that was *just* installed doesn't get mistaken
for a broken install.

### Trap 2: truncating a long build's output can make it silently hang

`flutter run` on Android streams continuous progress output for several
minutes on a first build (Gradle downloading the NDK, compiling). Piping
that through something that stops reading after N lines —

```powershell
flutter run ... 2>&1 | Select-Object -First 60
```

— does not just truncate what gets *displayed*. If the underlying process
writes faster than something is reading, and the reader stops reading
early, the process can block once its output buffer fills, because
nothing is left draining it. From outside, this looks exactly like a
silently frozen build: the log stops updating, and it's genuinely
ambiguous whether the process died, is stuck, or is just slow.

**What actually happened here:** exactly this. The log looked frozen for
several minutes. The fix was not to keep staring at the log, but to check
the *real* underlying process state instead — see §10.

**The actual fix: never truncate a long-running process's output stream.**
Redirect to a file instead, and read the file separately (tailing a file
does not affect the writer):

```powershell
flutter run -d 10.3.7.164:5555 --release *> "flutter_run.log"
```

then, from anywhere else, at any time:

```bash
tail -f flutter_run.log
```

---

## 10. How to tell whether a stalled-looking build is really stuck

A quiet log is not proof of a dead process — this project hit the same
lesson once already with a Postgres pipeline (see
`docs/plain-explanations.md`). The reliable check is the process's own
resource use over a real time window, not the log.

**Step 1 — is it burning CPU?** Take two readings a real 30–60 seconds
apart and compare, don't trust a single snapshot:

```powershell
(Get-Process -Id <gradle-java-pid> | Measure-Object CPU -Sum).Sum
# wait a real 30-60 seconds
(Get-Process -Id <gradle-java-pid> | Measure-Object CPU -Sum).Sum
```

If the second number is meaningfully higher, it is genuinely working —
just slow (first Android builds download an NDK that can be 1+ GB; this
is normal and one-time).

**Step 2 — if CPU barely moved, check the network instead of assuming
"stuck."** A build can be legitimately idle-on-CPU while waiting on a slow
download, which is not a hang:

```powershell
Get-NetTCPConnection -OwningProcess <pid> | Select-Object RemoteAddress, RemotePort, State
```

A handful of `Established` connections to a package repository = genuinely
downloading, just slow — leave it alone. **What was actually seen here**
was dozens of connections in `CloseWait` state to Google's servers, with
almost no CPU movement — that combination means the remote side had
already closed the connections and the build was stuck retrying rather
than making progress. That is the actual signal to stop waiting and act.

**Step 3 — if it's genuinely stuck, stop it cleanly and restart with
output going to a real file** (§9, trap 2), so the next check has an
actual log to read instead of repeating steps 1–2 blind:

```powershell
Stop-Process -Id <pid1>,<pid2>,... -Force
```

Kill the whole process tree the build spawned (the `flutter` process
itself plus any `java`/Gradle child processes it started), not just the
top-level one — a build tool that spawns workers can leave orphans behind
otherwise, the same "abandoned job still holding locks" trap documented
in `docs/plain-explanations.md` for the database pipeline.

---

## 11. Then what

The stack for Phase 6 is fixed in CLAUDE.md §6:

| purpose | package |
|---|---|
| maps | `maplibre_gl` — avoids Google Maps billing |
| on-device storage / offline | `sqflite` |
| state management | `riverpod` |

And the honest constraint to design around from day one: **there is no
live vehicle feed right now.** The recorder was deliberately stopped, so
the screens that can be built truthfully today are route browsing, stop
search, timetables, and "if a bus is at stop N, when does it reach stop M"
— the working `/eta` endpoint. The headline "buses arriving at this stop
right now" screen needs the recorder running again.

Designing the app as though live data exists, and filling it with
historical data, would be exactly the dishonesty this project was built to
correct.
