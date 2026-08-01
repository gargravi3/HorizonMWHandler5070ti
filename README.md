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

Copy into the Nucleus install so the script folder name matches the handler file name:

```
C:\NucleusCoop\handlers\HorizonMW.js
C:\NucleusCoop\handlers\HorizonMW\HMWConnectHotkey.bat
C:\NucleusCoop\handlers\HorizonMW\HMWConnectHotkey.ps1
```

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
