# HorizonMW Nucleus Co-op handler

Split-screen handler that runs N instances of **HorizonMW** (HMW), a mod of *Call of Duty:
Modern Warfare Remastered*, under [Nucleus Co-op](https://github.com/SplitScreen-Me/splitscreenme-nucleus).
Every instance gets its own save data and its own online identity, and guests join the host
with one keypress.

Derived from birden's `Call of Duty Modern Warfare Remastered.js` handler
(hub handler id `hpthpqPEFTZfwAFhT`).

## Layout

| Path | Purpose |
|---|---|
| `HorizonMW.js` | the handler |
| `HorizonMW/HMWConnectHotkey.bat` | starts the F2 watcher hidden and detached |
| `HorizonMW/HMWConnectHotkey.ps1` | the F2 watcher itself |

## Install

Run `install.ps1`, which copies every file to the right place and verifies each one by
hash:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1        # -NucleusRoot to override
```

The layout it produces, which matters more than it looks:

```
C:\NucleusCoop\handlers\HorizonMW.js            <- the handler. Nucleus loads ONLY this
C:\NucleusCoop\handlers\HorizonMW\              <- Context.ScriptFolder at runtime
C:\NucleusCoop\handlers\HorizonMW\Graphics\     <- preset files
C:\NucleusCoop\handlers\HorizonMW\HMWConnectHotkey.bat
C:\NucleusCoop\handlers\HorizonMW\HMWConnectHotkey.ps1
```

**Nucleus does not scan subfolders for handlers.** Putting `HorizonMW.js` in the asset
folder next to the presets looks right, verifies clean against its own target and does
nothing at all: the frame cap dropdown was installed that way once and never appeared,
because the older copy at the handlers root kept being loaded. The two files were one
commit apart, so nothing about the running handler looked stale. That is the reason
`install.ps1` verifies destinations by hash instead of trusting the copy.

Handlers are parsed when Nucleus starts, so **restart Nucleus** after installing or the
previous version keeps serving.

Restart Nucleus, add the game, and point it at `hmw-mod.exe` in the HorizonMW install
(`...\steamapps\common\Call of Duty Modern Warfare Remastered\hmw-mod.exe`).

## How to play

1. Launch all instances and wait until they have finished resizing and repositioning.
2. On instance 1, host a private/custom match.
3. Press **F2** once. Every guest is focused in turn and sent `connect 127.0.0.1:27016`
   through its console.
4. Keyboard/mouse players: press **END** once to lock input so each instance gets its own
   cursor and keyboard. F2 only works while input is *unlocked*.

## What the handler does

**Launch model.** `hmw-mod.exe` is both launcher and game process, so `Game.ExecutableName`
is `hmw-mod.exe` and `Game.LauncherExe` is deliberately left unset. If both named the same
binary, Nucleus would start a process and then search by name for a process to attach to,
which is ambiguous once a second instance exists. `Game.SymlinkExe = false` plus an explicit
`File.Copy` gives each instance a real copy of the exe, because HMW writes next to it and
self-updates.

**Ports.** Each instance gets `+set net_port 27016 + PlayerID * 2`. The engine uses
`port` and `port + 1`, hence the step of 2. Guests always connect to the host's 27016.

**Save isolation.** A populated `players2\` is created inside each instance folder:
`config_mp.cfg`, `keys_mp.cfg`, `settings_c.zip.h1`, `settings_m.zip.h1` are seeded from the
real install, and `favourites.json`, `history.json`, `user\hmwcdta`, `user\hmwdta` are seeded
or created empty (HMW can stall on first launch without them). Seeding only happens when the
instance has no file yet, so player edits survive relaunch.

**Identity isolation.** HMW identifies a player by `%LOCALAPPDATA%\hmw-mod\hwgd.pf`. If all
instances report the same GUID the HMW server treats them as one player connecting repeatedly
and they kick each other off. Each instance is given
`{00000000-0000-4000-8000-00000000000<N>}`. Only instance 1 keeps the real account keypair
(`hmw-key`, `hmw-key.pub`); guests run anonymously, otherwise the server sees one account
logging in several times.

**Identity backup.** Before the first modification, `hwgd.pf`, `hmw-key` and `hmw-key.pub` are
copied to `*.nucleus-original` (only if the backup does not already exist). They are restored
and the backups deleted when the session ends. Restore runs from two places, see below.

## Deliberate deviations from the build spec

1. **`hwgd.pf` terminator is `0x00`, not `\n`.** The spec asked for a trailing newline to reach
   39 bytes. The pristine file HMW writes itself is 38 ASCII characters followed by a single
   NUL byte, so this handler writes a NUL. Byte count is identical (39) and the terminator now
   matches HMW's own output exactly, which matters because HMW reads the file into a
   fixed-size buffer. Verified by reading the bytes of a pristine
   `%LOCALAPPDATA%\hmw-mod\hwgd.pf` (last three bytes `0x33 0x7D 0x00`). The handler logs a
   warning if the file it wrote is not 39 bytes.

2. **`Game.UseForceBindIP = false`** (the base MWR handler sets it to `true`). ForceBindIP pins
   each instance to a specific local IP; the guests' `connect 127.0.0.1:27016` would then not
   reach the host. Instance separation here comes from unique UDP ports instead.

3. **Identity restore is implemented twice.** `Game.OnStop` exists on Nucleus'
   `GenericGameInfo` as a `System.Action` field but is not documented in Nucleus' `readme.txt`,
   so the same idempotent restore also runs in the `finally` block of the F2 watcher, which
   lives for the whole session and exits ~30 s after the last `hmw-mod.exe` disappears. Both
   copy the backup back and then delete it, so a double run is harmless.

4. **Player name is written by a scan-and-append routine**, not
   `Context.ReplaceLinesInTextFile`, which silently drops writes for lines that do not already
   exist. Names are `Player1 .. PlayerN` from `Context.PlayerID`, not Nucleus profile
   nicknames, so they are guaranteed distinct.

5. **`Game.GUID = "HorizonMW"`**, so instances live in `content\HorizonMW\InstanceN` rather
   than sharing the stock MWR handler's content folder.

6. **`Game.KillProcessesOnClose` is empty.** The watcher runs inside `powershell.exe` and
   killing every `powershell.exe` would take the user's own shells with it. It shuts down via a
   stop sentinel written by `Game.OnStop`, or by its own idle timeout.

7. **No graphics, FOV, FPS or resolution options.** Out of scope for the first working version,
   so the handler writes exactly one dvar (`seta name`). The source `config_mp.cfg` has
   `r_fullscreen "1"` with `r_fullscreenWindow "1"`, i.e. borderless windowed, which Nucleus
   can still resize and reposition. If positioning misbehaves, `r_fullscreen`,
   `r_fullscreenWindow`, `r_mode`/width/height are the first dvars to add.

## Controllers

ProtoInput provides the per-instance gamepad; the base MWR handler's ProtoInput block and its
`OnInputLocked` / `OnInputUnlocked` callbacks are carried over unchanged, with the XInput hook
enabled.

**`Game.ProtoInput.UseOpenXinput` must stay `false`.** Nucleus ships only a 32-bit
`openxinput1_3.dll` (PE machine `0x14C`) and `hmw-mod.exe` is 64-bit (PE machine `0x8664`), so
that DLL can never load into the game. On Windows 11 the failed load faults inside ntdll's
Switchback compatibility path instead of returning an error and kills the game about a second
after ProtoInput injects, which is `PauseBetweenProcessGrab` seconds after launch and therefore
looks like a random ~30 s crash. Standard XInput caps at 4 pads, which is the practical limit
anyway.

Do not run XInputPlus alongside ProtoInput; doubling up the restriction breaks wireless
controllers.

## Session 1 findings (31 Jul 2026, 23:48)

Two instances launched, save and identity isolation worked, `Game.OnStop` fired and restored
the identity files. Two problems, both now addressed.

### Instance 2 crashed and Nucleus reported "ProtoInput failed to runtime inject"

The crash and the injection failure are one event, not two: the injection attempt itself
faulted inside the game process, which both killed the game and left Nucleus reporting a failed
inject. From the Windows Error Reporting record (`AppCrash_hmw-mod.exe_...\Report.wer`):

- process start `23:49:40.503`, crash `23:50:11`, i.e. **30.5 s after launch** while
  `Game.PauseBetweenProcessGrab` was `30`. The crash is the injection moment.
- faulting module `ntdll.dll`, exception `0xc0000005`, offset `0xb1eb`.
- of the 125 loaded modules, **no ProtoInput or EasyHook module is present**, so the DLL never
  finished loading. The fault is inside the loader during injection.
- instance 1 was not affected; only one crash event exists.

Ruled out along the way:

- **Not the 32-bit `openxinput1_3.dll`.** `UseOpenXinput` was already `false` and no
  `openxinput*` or instance-local `xinput*` DLL appears in the loaded module list. Every
  non-Windows module loaded was x64.
- **Not a shared-file conflict.** `%TEMP%\h1-tlsdll.dll`, which hmw-mod writes and loads, was
  last modified at 11:37 that morning, so neither instance rewrote it under the other. Both
  instances mapping the shared `%LOCALAPPDATA%\hmw-mod\bin\h1_mp64_ship.exe` read-only was
  also fine, it is in the loaded module list of the crashed process.

Fix: switched from `InjectRuntime_EasyHookStealthMethod` to `InjectRuntime_EasyHookMethod`.
ProtoInput's own readme says *"For runtime injection, EasyHook Inject will work for most games.
If it doesn't, try Remote Load Library. Some games that block injection may work with Stealth
Inject."* The base MWR handler was using the last-resort method against a different binary
(`h1_mp64_ship.exe`, spawned by a launcher) than we inject into here.

If injection still fails, enable exactly one of the four `Game.ProtoInput.Inject*` lines. Try
them in this order: `InjectRuntime_EasyHookMethod`, `InjectRuntime_RemoteLoadMethod`,
`InjectStartup`, `InjectRuntime_EasyHookStealthMethod`. If all four fail, the next thing to
try is `Game.SetWindowHook = false`, since that injects a second Nucleus DLL at the same moment.

### Instance 1 repositioned too slowly

Same root setting: `Game.PauseBetweenProcessGrab = 30` meant Nucleus waited half a minute after
launch before grabbing the process and moving the window. The base handler needs 30 because
`h1-mod.exe` has to spawn a separate `h1_mp64_ship.exe`; `hmw-mod.exe` is the game process from
the start. Lowered to **15**. Raise it again if an instance gets grabbed before its window
exists. `Ctrl+R` re-runs the repositioning by hand at any time.

### Handler log was silently empty

`hmwLog` used `System.DateTime.Now.ToString("HH:mm:ss")`. Jint raises *"Object has no method
'ToString'"* on that, and `hmwLog` swallows its own exceptions, so every log write was a no-op
and the first diagnosis had to come from Windows crash reports instead. The timestamp is now
built in plain JS, and `tests/dryrun-helpers.ps1` asserts a log line actually lands.

`DebugLog` was also switched to `True` in `C:\NucleusCoop\Settings.ini` so the next run records
the Nucleus-side injection error text in `C:\NucleusCoop\content\app.log`. Set it back to
`False` when no longer needed.

## Session 2 (1 Aug 2026, 00:07) - first working run

Two instances launched, stayed up, and **each got its own controller**. No crash. The
`PauseBetweenProcessGrab = 15` plus EasyHook runtime injection change fixed it. Handler log:

```
[00:07:03] === Play() instance 0 -> ...\Instance0
[00:07:03] args: -nosteam -multiplayer +set net_port 27016
[00:07:03] backed up hwgd.pf / hmw-key / hmw-key.pub
[00:07:03] guid {00000000-0000-4000-8000-000000000001}
[00:07:03] host keypair in place
[00:07:33] === Play() instance 1 -> ...\Instance1
[00:07:33] args: -nosteam -multiplayer +set net_port 27018
[00:07:33] guid {00000000-0000-4000-8000-000000000002}
[00:07:33] guest runs anonymously
[00:09:17] === OnStop, restoring identity
```

Confirmed working: per-instance ports, per-instance `players2`, per-player GUIDs, host keeps the
real keypair while guests are anonymous, identity backed up and restored, `Game.OnStop` fires,
no `hmw-mod.exe` crash in the Windows event log, and `%LOCALAPPDATA%\hmw-mod` left byte-identical
to how it started with no stray `.nucleus-original` files.

Still broken in that run: the F2 host-join. See the next section.

## Session 3 (1 Aug 2026, 00:22) - F2 host-join working

Full working multiplayer: two instances, isolated saves and identities, per-instance controllers,
and the guest joining the host on one keypress. Watcher log:

```
[00:22:18] watcher started, pid 6252, variant KeysToggle
[00:23:41] connecting 1 guest(s) using KeysToggle: instances 1
[00:23:41]   instance 1 pid 6964 hwnd 1247502
[00:23:45] done
```

Compare the same code path in session 2:

```
[00:08:31] F2: connecting guests 0, 1
[00:08:31]   instance 0 1 pid 4184 22428
[00:08:31] restored hwgd.pf          <- mid-session, the bug
```

Every symptom is gone. One guest instead of a nested array, instance 1 only so the host is no
longer told to connect to itself, a single pid and a single window handle, and no identity
restore during the session. Start to finish in 4 s for one guest, which matches the per-guest
budget of 500 + 200 + 1000 + 750 ms plus focus time.

## Session 6 (1 Aug 2026, 01:01) - everything working

Two instances, correct split geometry, no crash, and F2 host-join. The complete goal.

The timing fix landed exactly as predicted. `PauseBetweenStarts = 25` shows up as
`Pausing for 25 seconds`, and the last instance's grace went from the 28 s that crashed to 43 s:

| | launch | repositioned | grace |
| --- | --- | --- | --- |
| instance 0 | 01:01:54 | 01:02:54 | 60 s |
| instance 1 | 01:02:39 | 01:03:22 | **43 s**, predicted 43 s |

```
[01:02:54] Attempting to reposition, resize and strip borders for instance 0 (pid 19876)
[01:03:22] Attempting to reposition, resize and strip borders for instance 1 (pid 15952)
[01:04:24] connecting 1 guest(s) using KeysToggle: instances 1
[01:04:24]   instance 1 pid 15952 hwnd 68966
[01:04:28] done
[01:08:05] no hmw-mod.exe for a while, exiting
[01:08:05] restored hwgd.pf / hmw-key / hmw-key.pub
```

No `ERROR - ResetWindows was unsuccessful` anywhere in the session, where session 5 had it for
instance 1, and no `hmw-mod.exe` entry in the Windows Application log. The watcher also exercised
its idle-exit path, restoring the identity files because the session ended without `Game.OnStop`.

Verified working end to end:

- N instances launching from a single `hmw-mod.exe` that is both launcher and game
- per-instance `players2`, so saves, loadouts and settings do not collide
- per-instance identity via `hwgd.pf`, host keeps the real keypair, guests are anonymous, and the
  user's real `%LOCALAPPDATA%\hmw-mod` is backed up and restored
- per-instance ports, 27016 + PlayerID * 2
- one controller per instance
- windows positioned and resized to their slice without cutting the image off
- F2 joining every guest to the host's private match
- identity restored on normal exit, on Nucleus shutdown, and on the watcher's idle path

## Session 8 (1 Aug 2026, 01:42) - three instances, the third fail-fasted after loading

This run had `DebugLog=True`, so there is a full Nucleus log for it. **Graphics was `Default`**, no
preset line appears in the handler log, which makes this a clean test of the multi-instance path.

All three instances launched and **all three had ProtoInput injected successfully**:

```
[01:40:31] Launching Instance0 ... [01:40:46] Obtained pid 25024, Injecting ProtoInput
[01:41:17] Launching Instance1 ... [01:41:32] Obtained pid 2096,  Injecting ProtoInput
[01:42:02] Launching Instance2 ... [01:42:17] Obtained pid 22188, Injecting ProtoInput
[01:42:43] Process is no longer running. Attempting to find process by window title
[01:44:24] All instances accounted for, performing final preperations
[01:44:25] Killing process hmw-mod (pid 2096) / (pid 25024)      <- only two, 22188 already dead
```

Crash, from the event log and WER:

```
Faulting application path: ...\HorizonMW\Instance2\hmw-mod.exe
Faulting module name:      h1_mp64_ship.exe
Exception code:            0xc0000409          STATUS_STACK_BUFFER_OVERRUN
Sig[6] (fault offset):     0x000000000081f4ec
EventType:                 BEX64
loaded modules:            135, including ProtoInputHooks64.dll and nvwgf2umx.dll
```

`0xc0000409` is a **deliberate fail-fast**, the game's own `/GS` or `__fastfail` check firing, not a
stray access violation. 135 modules with the NVIDIA user-mode driver mapped means it was fully
loaded, matching "crashed after loading". It died 28 s after launch and 13 s after injection.

### What this rules out

- **Not a ProtoInput injection failure.** `ProtoInputHooks64.dll` is in the crashed process. Injection
  worked for all three.
- **Not the graphics preset.** This run applied none.
- **Not the reposition path.** Instance 2 was never repositioned; it died at 01:42:30, and "final
  preperations" was 01:44:24. Nucleus then spun for 101 s on `Update data process has not exited`.

### Two distinct failures, not one

The 01:30 and 01:42 crashes are different bugs, and conflating them would be a mistake:

| | 01:30 (4 instances, `Low`) | 01:42 (3 instances, `Default`) |
| --- | --- | --- |
| instance | 1 | 2 |
| when | 6 s after launch, **before** grab | 28 s after launch, **after** injection |
| code | `c0000005` at address `0x8` | `c0000409` fail-fast |
| modules | 84, no ProtoInput, no `nvwgf2umx` | 135, ProtoInput present, `nvwgf2umx` present |
| stage | during D3D11 device creation | fully loaded and running |

Instance 1 survived the whole of this preset-free run, which it did not in the 01:30 preset run. That
is now consistent with the graphics preset having caused the earlier crash, and it is the reason
`sm_enable "0"` and the out-of-range `r_picmip_water "3"` were taken out.

### Where the third instance differs

Worth noting for whoever picks this up. Instance 2 was the only instance that had **not** received
Nucleus's legacy keyboard/mouse hook DLL, because that is injected into already-running instances
when the *next* player is set up, and there was no player 4:

```
[01:41:15] Injecting hook DLL for previous instance   <- into instance 0
[01:41:59] Injecting hook DLL for previous instance   <- into instance 1
```

So the instance with *fewer* hooks is the one that died, which argues against a simple
double-hooking explanation. It also had no controller: nothing XInput was connected during this run.

`Game.SupportsMultipleKeyboardsAndMice = true` enables that legacy layer, and the Nucleus readme
marks it deprecated in favour of ProtoInput. birden's working MWR handler sets it too, so it is not
by itself the difference. The two settings that *do* differ from that known-good handler are
`InjectRuntime_EasyHookMethod` (birden uses `EasyHookStealthMethod`) and `UseOpenXinput = false`
(birden uses `true`, though HMW's bundled `openxinput1_3.dll` is 32-bit while `hmw-mod.exe` is 64-bit).

### Not yet determined

The cause of the fail-fast is unresolved. It needs a game run per hypothesis, so it cannot be settled
from logs alone.

## Session 7 (1 Aug 2026, 01:30) - instance 1 died 6 s into startup

The reported "ProtoInput failed to inject" is a **symptom, not the cause**. The timing rules it out:

| time | event |
| --- | --- |
| 01:30:26 | instance 1 `Play()`, launch |
| **01:30:32** | **instance 1 crashes** |
| 01:30:41 | Nucleus grabs instance 1 and only then injects ProtoInput |

Injection happens 9 s *after* the process was already dead, which is also why the WER module list has
no `ProtoInputHooks64.dll`. The process died before injection was attempted.

Crash signature, from WER: `EventType=BEX64`, `c0000005`, faulting address `0x0000000000000008`, a
null pointer plus 8, faulting module "unknown". 84 loaded modules against 125 and 135 in the two
earlier crashes, so it died far earlier in startup. `d3d11.dll` and `dxgi.dll` were mapped but
`nvwgf2umx.dll`, the NVIDIA D3D11 user-mode driver, was not, which places the crash **inside D3D11
device creation**.

Only instance 1 crashed. Instance 0 ran the same 12 preset dvars and survived, and the run was
stopped by hand at 01:31:37, so instances 2 and 3 never launched.

### What the crash config proved

Because instance 1 crashed it never rewrote `config_mp.cfg`, so the file on disk is exactly what the
handler wrote. Instance 0 exited cleanly and rewrote its own, so comparing the two shows which values
HMW **rejected**:

```
dvar                  written   instance 0 kept
r_picmip              3         3
r_picmip_bump         3         3
r_picmip_spec         3         3
r_picmip_water        3         1     <- silently clamped
sm_enable             0         0
```

`r_picmip_water` maxes out at **1**, not 3. All presets were corrected. Everything else, including
`sm_enable "0"`, was accepted and persisted, so those values are not invalid.

### Architecture this uncovered

The crashing process's module list shows the per-instance `hmw-mod.exe` copy isolates less than it
appears to. The real game binary and its DLLs come from shared locations:

```
C:\Users\gargr\AppData\Local\hmw-mod\bin\h1_mp64_ship.exe
C:\Users\gargr\AppData\Local\Temp\h1-tlsdll.dll
...\steamapps\common\Call of Duty Modern Warfare Remastered\{D3DCOMPILER_47,steam_api64,amd_ags_x64,bink2w64}.dll
```

`Instance1\hmw-mod.exe` is a byte-identical copy of the install exe, but it loads the actual game out
of `%LOCALAPPDATA%\hmw-mod\bin`, which every instance shares. Worth knowing before blaming
per-instance state for anything.

### Changes made

- `r_picmip_water` corrected to its real maximum of 1 in every preset. This is the one proven bug.
- `sm_enable "0"` removed from `Low` and left commented out with a note. It is the most invasive
  value in the preset, and renderer init is where the crash happened, but the game accepted it and
  instance 0 ran with it, so it is a suspect and not a proven cause. `Low` now reduces
  `sm_maxLightsWithShadows` to 1 instead.
- `DebugLog` was found set back to `False` in `Settings.ini`, which is why there is no
  `debug-log.txt` for this run at all. Set back to `True`.

### Still unproven

The graphics preset is a suspect because it is the only new thing that affects startup before the
grab, and the crash is in renderer init. It is **not** proven: instance 0 ran the identical config.
To settle it, run 4 instances with **Graphics = Default**. If instance 1 still dies 6 s in, the
preset is exonerated and the cause is in the multi-instance startup path. If it survives, the preset
is confirmed and the next step is bisecting `Low.cfg`.

Note also that 4 instances have never yet started successfully, so that path is untested independently
of the preset.

## Graphics presets

Nucleus game options menu, **"Graphics preset for every instance"**: `Default`, `Low`, `Medium`,
`High`, `Extra`. Drop it for 4 instances, raise it for 2. It applies to every instance.

`Default` is the default selection and changes nothing, so an existing setup behaves exactly as
before until a preset is picked.

Each other entry is a plain text file of `seta` lines in `handlers\HorizonMW\Graphics\`. **They are
meant to be edited.** Only the dvars a file actually lists are touched; everything else is left as
it was.

### Why files rather than the stock handler's approach

The stock MWR handler implements the same option by copying a whole prebuilt config over
`players2\config_mp.cfg`:

```js
var savePkgOrigin = System.IO.Path.Combine(Game.Folder, "Config\\config_mp_low_opt.cfg");
System.IO.File.Copy(savePkgOrigin, savePath, true);
```

That is not usable here for two reasons. It would discard everything this handler writes
per-instance, the player name, the windowed-mode dvars and the FPS setting, and those shipped
configs use MWR's *hashed* dvar names (`seta 0x617FB3B4 "1"`), which HMW's config does not use.

### Why the shipped presets are conservative

HMW has no master quality dvar, just ~15 individual ones, and several are string enums whose other
accepted values are undocumented:

```
seta sm_tileResolution "High"
seta r_postAA "None"
seta r_depthPrepass "All"
seta sm_cacheSpotShadows "Disabled"
```

A rejected value is *silently ignored* by this engine rather than reported. That is exactly how
`r_mode "2560x720"` got quietly rewritten to `2560x1440`, which is what put a window half
off-screen and crashed an instance. So the shipped presets only set dvars whose type and direction
are unambiguous: the `r_picmip` family, `r_texFilterAniso*`, `sm_enable`,
`sm_maxLightsWithShadows`, `r_drawWater`, `fx_marks`, `ai_corpseLimit`, `ragdoll_mp_limit`,
`r_vsync`. `Extra` also sets `sm_tileResolution "High"`, and only because `"High"` is the value the
untouched install already had, so it is known to be accepted.

Treat the shipped values as a starting point, not as HMW's own presets. They are not, and there is
no way to read HMW's real preset tables from outside the game.

### Capturing a preset that is guaranteed valid

`Capture-GraphicsPreset.ps1` builds a preset from the game's own values, so nothing is guessed:

```powershell
# 1. launch through Nucleus with Graphics = Default
# 2. set the graphics you want in one instance and apply
# 3. quit that instance, so HMW flushes config_mp.cfg
cd C:\NucleusCoop\handlers\HorizonMW
.\Capture-GraphicsPreset.ps1 -Name Low -Instance 0 -Force
```

It warns if `hmw-mod.exe` is still running, because HMW only writes `config_mp.cfg` on exit, so a
capture taken while the game is open misses whatever was just changed in the menu.

### Dvars a preset may never set

`r_fullscreen`, `r_fullscreenWindow`, `r_mode`, `vid_xpos`, `vid_ypos`, `name`.

These are ignored with a log line even if a preset file lists them, because the handler owns them.
A preset putting `r_fullscreen` back to `"1"` or pinning `vid_ypos` at a slice offset would undo the
two fixes that each took a crash to find, and setting `name` would collapse every instance onto one
player profile. There is a test that empties the blocklist and confirms the same preset file then
does break all three, so the guard is doing real work.

Preset application runs *after* the windowed-mode and FPS passes, so a preset can override things
like `r_renderResolutionNative`, but not the blocked list.

## Frame cap

Nucleus game options menu, **"Frame cap per instance (fps)"**: `60`, `90`, `144`, `240`. Written to
every instance as `com_maxfps`. `60` is first and therefore the default.

This is the largest GPU saving available in the handler and it costs nothing visually. The install
config ships `com_maxfps "0"`, meaning uncapped, so each instance renders as fast as it can and
several instances compete for one GPU producing frames nobody sees. On a 240 Hz display, four
uncapped instances are asking for up to 960 frames a second.

Every offered value divides 240 exactly, so frames land on refresh boundaries: `240/4 = 60`,
`240/2 = 120` near the `144` entry. There is deliberately **no uncapped choice**, because uncapped is
the setting the option exists to prevent. An unrecognised or missing selection falls back to `60`
with a log line rather than being written through, for the same reason: skipping would leave
`com_maxfps "0"`, and `com_maxfps "abc"` in a config is indistinguishable from a GPU that cannot keep
up, which is a miserable thing to diagnose.

`com_maxfps` is on the preset blocklist, so a hand-edited preset file cannot quietly outrank the
dropdown, and the cap is applied *after* the preset pass so the dropdown is the last word. Both
properties have tests, including one that reverses the order and requires a failure.

Sizing guidance, for a 1080p display with four instances in a 2×2 grid:

| Instances | Each window | Total pixels/frame | Suggested cap |
|---|---|---|---|
| 2 | 960×1080 | 2.07 MP | 120 or 144 |
| 3 | 960×540 | 1.55 MP | 90 |
| 4 | 960×540 | 2.07 MP | 60 |

Note the preset matters more than the cap at four instances. Video memory was measured at 5,463 MiB
per instance at `Default`, so four instances need about 22.5 GB against the 16.3 GB this card has, and
`Low` is not optional there. The cap reduces GPU *time*, not GPU *memory*, so the two options solve
different problems and neither substitutes for the other. Per-instance memory at `Low` has not been
measured yet.

## FPS counter

On in every instance by default. Set `HMW_SHOW_FPS = false` at the top of `HorizonMW.js` to leave
whatever each player last chose in-game instead.

The dvar is **`cg_infobar_fps`**, not the stock `cg_drawFPS`. That was settled empirically rather
than guessed: the counter was toggled on in-game in one instance, then that instance's
`config_mp.cfg` was diffed against another's. `cg_infobar_fps` was the only render dvar that moved,
and `cg_drawFPS` stayed `"0"` in both, so writing the stock dvar would have done nothing visible
and writing both risks two overlapping readouts.

`cg_drawFPSLabels` is already `"1"` out of the box and is left alone. Worth knowing:
`seta cg_drawFPS ` is a prefix of `seta cg_drawFPSLabels `, so `hmwSetCfgValue`'s trailing space is
what keeps them apart. There are tests for both that collision and for the opt-out path.

Reapplied on every launch, like the windowed-mode pass, because HMW rewrites `config_mp.cfg` on
exit. A player who turns the counter off in-game therefore gets it back next launch unless
`HMW_SHOW_FPS` is false.

## Session 5 - instance 1 crashed during "reposition, resize and strip borders"

Session 4 looked much better but instance 1 died just as it was moved to its slice. The Nucleus
debug log puts the crash and the resize at the same second:

```
[00:49:28] Attempting to reposition, resize and strip borders for instance 0 (pid 23332)   <- survived
[00:49:41] Attempting to reposition, resize and strip borders for instance 1 (pid 18536)
[00:49:41] *** hmw-mod.exe faults, exception e06d7363 in KERNELBASE.dll ***
[00:49:43] ERROR - ResetWindows was unsuccessful for instance 1
```

`0xe06d7363` is the MSVC C++ exception marker, so HMW threw and nothing caught it. `ResetWindows`
then "failed" only because the process was already gone. This is a different failure from the
session 2 crash, which was `0xc0000005` in `ntdll` with no ProtoInput module loaded; here
`ProtoInputHooks64.dll` is in the module list and D3D11 came up, so injection is fine.

Two independent causes, both self-inflicted by the session 4 fix.

### 1. r_mode was silently rejected, which made vid_ypos put the window off-screen

Both instances rewrote `r_mode` back to `2560x1440` on exit. `r_mode` only accepts a resolution the
monitor enumerates, and `2560x720` is not one of the 23 this display offers, where the only `*x720`
entry is `1280x720`. So the split-size write achieved nothing, and the visual improvement in
session 4 came entirely from `r_fullscreen "0"`, which let Nucleus resize the window.

That matters because of what it does to `vid_ypos`. With `r_mode` back at native, instance 1 was
told to create a **2560x1440** window at **y=720** on a **1440** tall screen, so half of it hung off
the bottom. Instance 0 got `y=0` and was entirely on-screen. That is the only value that differed
between the instance that crashed and the instance that survived.

Sizing and positioning are now left entirely to Nucleus. `r_mode` is not written at all, and
`vid_xpos`/`vid_ypos` are pinned back to the stock `-1`.

Pinning them explicitly rather than just not writing them is the point: an instance set up by the
session 4 build still has `vid_ypos "720"` on disk, and HMW rewrites `config_mp.cfg` on exit, so
merely stopping would have let the crash reproduce forever. There is a test for exactly that.

### 2. The last instance gets far less startup grace than the others

Every instance except the last is repositioned when the *next* one is grabbed. The last one is
repositioned immediately during "final preperations":

| | launch | repositioned | grace |
| --- | --- | --- | --- |
| instance 0 | 00:48:43 | 00:49:28 | 45 s, survived |
| instance 1 | 00:49:13 | 00:49:41 | 28 s, crashed |

`PauseBetweenStarts` is what buys that time, so it goes from 10 to 25, putting the last instance at
roughly 43 s. `PauseBetweenProcessGrab` stays at 15 so the earlier "didn't reposition fast enough"
complaint does not come back. Two-player startup gets about 15 s longer.

## Session 4 - the second instance was cut off at the split boundary

The handler set `Game.SupportsPositioning` and `Game.ResetWindows` and left it there, writing no
resolution dvars at all. Both instances were therefore launching with the config they inherited
from the install:

```
seta r_fullscreen       "1"
seta r_fullscreenWindow "1"
seta r_mode             "2560x1440"
```

On this single 2560x1440 monitor that means each instance rendered a full-screen 2560x1440
backbuffer. Nucleus moved and resized the *window*, but the game kept rendering full-screen, so
for a horizontal 2-way split the second instance's window sits at y=720 with a 1440-tall client
area and everything below the split boundary is off-screen. Positioning alone cannot fix that;
the game has to be told to render smaller.

`hmwApplyViewport` now writes, on every launch:

| dvar | value | why |
| --- | --- | --- |
| `r_mode` | `<Width>x<Height>` | HMW stores resolution as one `WxH` string, not a width and a height dvar |
| `r_fullscreen` | `0` | windowed, so the window can be sized to the slice |
| `r_fullscreenWindow` | `0` | not borderless-fullscreen |
| `r_aspectRatio` | `auto` | a 2560x720 slice is not 16:9 |
| `r_renderResolutionNative` | `0` | so the count below is used |
| `r_renderResolution` | `Width*Height/1e6` | render target sized to this instance's slice |
| `vid_xpos` / `vid_ypos` | `PosX` / `PosY` | correct on the first frame instead of waiting for Nucleus to move it |

Two things worth knowing:

- **`r_renderResolution` is a megapixel count**, not a scale. The install had `"3.6864"`, which is
  exactly 2560x1440 / 1e6.

  This used to pin `r_renderResolutionNative "1"` and leave the count alone, on the assumption that
  "native" meant the window. **Nothing ever supported that assumption.** Every instance kept
  `r_renderResolution "3.6864"` and `r_mode "2560x1440"` while displaying in a 960x540 window, and
  Low measured about 3,750 MiB of video memory per instance, which is far too much for a
  0.52 megapixel window with `picmip 3`. A 2560x1440 render target is seven times the pixels of that
  window, and at four instances that difference is what left only 530 MiB free and hung the third
  instance with a black screen.

  The count is now computed per instance from the slice Nucleus reports: `960x540` gives `0.5184`,
  `1280x720` gives `0.9216`, both exact. Because it is per-instance, no fixed value in a preset file
  can be right for every slice, so both dvars are on the blocklist.

  The prompt for looking was a fair question: a similar handler ran five instances on an 11 GB
  2080 Ti. That handler wrote the tile size into the config, in HMW's hashed-name dvars
  (`0x6E536C59 "1920"`, `0xF5470D48 "1200"`, which are real and present here). Whether HMW honours
  `r_renderResolution` in windowed mode is still unverified; if it does not, the cost is a setting the
  game ignores.
- **The Nucleus properties are `Context.PosX` and `Context.PosY`**, not `PositionX`/`PositionY`.
  Confirmed by reflection over `Nucleus.Gaming.dll`; `readme.txt` documents neither.

Rewritten on every launch rather than only when `players2` is seeded, because HMW saves
`config_mp.cfg` on exit and the split geometry changes with the player count and layout.

If the instances come up with a visible title bar stealing pixels, the first thing to try is
`r_fullscreenWindow "1"` with `r_fullscreen "0"`; on this engine that pairing is what usually
yields a borderless window. Nucleus's own `ResetWindows` handles border removal today, which is
why it is off.

### Testing this without launching the game

The viewport logic is a pure function of the four Nucleus numbers, so the suite drives it
directly, including the two mistakes that would otherwise ship silently:

- **dvar prefix collisions.** `hmwSetCfgValue` matches on `key + " "`, so `seta r_fullscreen `
  must not also match `seta r_fullscreenWindow `, and `seta r_renderResolutionNative ` must not
  match `seta r_renderResolution `. Both are asserted, along with a check that no dvar ends up
  duplicated.
- **CLR versus JS numbers.** Nucleus supplies `Context.Width` as a .NET `Int32`, not a JS number.
  Every literal-driven test would still pass if `parseInt` could not read that, while the real
  handler no-opped. The suite builds a CLR object with `Int32` properties, hands it to Jint as
  `Context`, and asserts the config is actually written. Jint does surface it as a JS `number`,
  so it works, but the test now pins that.

### Why F2 did nothing, and the fix

The watcher log gave it away:

```
[00:08:31] F2: connecting guests 0, 1
[00:08:31]   instance 0 1 pid 4184 22428
```

`Index` printed `0 1` and `Id` printed `4184 22428`, so those were not two guests, they were one
nested array. `Get-HmwInstances` ended with `,($result | Sort-Object Index)`. The unary comma
wraps the array, returning it unrolls the *outer* array and emits the inner array as a single
pipeline item, and `@(...)` then collects that one item. So `$all.Count` was 1 and its only
element was the whole array.

One line, three failures:

1. `$_.Index -ne 0` compared against an array, which returns a non-empty array, which is truthy,
   so **instance 0 was never excluded** and the host was told to connect to itself.
2. `$g.Handle` was an array of two handles, so binding it to `[IntPtr]$Handle` threw.
3. That exception escaped the loop into `finally`, which **restored the identity files while the
   game was still running** and killed the watcher, 4 s after F2.

Fixes:

- `Select-HmwGuest` emits objects one at a time; no unary comma anywhere. It is a pure function
  taking the process list as a parameter, so `-SelfTest` drives it with synthetic data. The
  suite asserts the exact regression (`each item is a single object`) plus instance-0 exclusion
  and numeric ordering, and the old line was replayed against those assertions to confirm it
  reproduces `instance 0 1 pid 4184 22428` exactly.
- The watcher only restores identity on the idle-exit path, when the game vanished without
  `Game.OnStop` running. An exception now logs and restores nothing.
- Wait for F2 to be released before sending anything, so a held key cannot leak into the game
  or start the sequence twice.
- `Stop-PreviousWatchers` now requires `-File` in the command line. Matching the script name
  alone also matched any shell that merely mentioned it, which is not hypothetical: a diagnostic
  command in this repo's own development killed itself that way.

### The F2 sequence

Per guest, in order, and only for guests (instance 0 is always excluded):

```
bring the guest window to the foreground, and verify it really is foreground
{~}                        open the console
connect 127.0.0.1:27016    type the command
{ENTER}                    run it
{~}                        close the console
```

Foreground is attempted up to 8 times, 250 ms apart, checking `GetForegroundWindow` each time;
after the third failure it taps Alt, which loosens Windows' foreground lock. A guest that never
comes to the foreground is skipped rather than risk typing the command into the wrong window.
Guests always connect to the host's `27016`, never to their own port.

This is the `KeysToggle` variant and it is the default. The script also has `PostToggle` and
`PostNoToggle`, which post window messages instead and need no focus change, mirroring the
`ControlSend` approach in birden's AutoIt implementation. To try one without relaunching
Nucleus, while the instances are up:

```powershell
powershell -NoProfile -STA -File "C:\NucleusCoop\handlers\HorizonMW\HMWConnectHotkey.ps1" -TestConnect
powershell -NoProfile -STA -File "...\HMWConnectHotkey.ps1" -TestConnect -Variant PostToggle
```

That fires one attempt immediately, prints the tail of the log, and exits. Change
`$DefaultVariant` at the top of the script if a different variant proves better.

Pressing F2 again re-runs the whole sequence, which is useful if a guest failed to connect,
dropped, launched late, or the host started a new match.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

Runs the handler helpers under Nucleus' own `Jint.dll` against a temp sandbox, the F2 guest
selection self test, and a syntax check of every `.ps1` plus `HorizonMW.js`. Nothing outside the
sandbox is touched.

## Troubleshooting

Three logs:

- `%TEMP%\HorizonMWHandler.log` - per-instance handler steps: ports, GUIDs, identity
  backup/restore, watcher startup.
- `%TEMP%\HMWConnectHotkey.log` - watcher lifecycle and every F2 press.
- `C:\NucleusCoop\content\app.log` - the Nucleus side, including ProtoInput injection errors.
  Needs `DebugLog=True` in `Settings.ini`. Renamed to `<date>_<time>.log` when Nucleus exits.

For a game crash, the most informative source is the Windows Error Reporting record:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} |
  Where-Object { $_.Message -match 'hmw-mod' } | Select-Object -First 1 -Expand Message
Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -Directory |
  Where-Object Name -like 'AppCrash_hmw-mod.exe*' | Sort-Object LastWriteTime -Desc |
  Select-Object -First 1 | Get-ChildItem | Get-Content | Select-String 'LoadedModule|Sig\['
```

The loaded module list tells you whether ProtoInput actually got in, and the fault offset plus
the interval between process start and crash tells you whether the crash coincides with
`PauseBetweenProcessGrab`.

If Nucleus is killed hard mid-session, `%LOCALAPPDATA%\hmw-mod\*.nucleus-original` may still be
present. Launch a session and close it normally, or copy those files back over their originals
by hand.
