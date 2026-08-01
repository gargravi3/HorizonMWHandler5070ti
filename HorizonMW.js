// ---------------------------------------------------------------------------
// HorizonMW (HMW) - Nucleus Co-op split-screen handler
//
// Derived from birden's "Call of Duty Modern Warfare Remastered" handler
// (hub.splitscreen.me handler id hpthpqPEFTZfwAFhT). The ProtoInput block and
// most window/hook settings carry over unchanged; the launch model, save
// isolation, identity isolation and host-join hotkey are HMW specific.
//
// Scope of this version: get N instances launching, isolated and connected.
// Graphics presets, FOV, FPS caps and resolution dvars are intentionally not
// touched.
// ---------------------------------------------------------------------------

var HMW_BACKUP_SUFFIX = ".nucleus-original";
var HMW_IDENTITY_FILES = ["hwgd.pf", "hmw-key", "hmw-key.pub"];
var HMW_HOST_PORT = 27016;

// Show HMW's FPS readout in every instance. Set to false to leave whatever each
// player last chose in-game, since this is reapplied on every launch.
var HMW_SHOW_FPS = true;

// --- small helpers ---------------------------------------------------------

// Timestamp is built in plain JS: Jint cannot call System.DateTime.Now.ToString(),
// it raises "Object has no method 'ToString'", which previously made every log
// write fail silently.
function hmwTimestamp() {
  var d = new Date();
  function p(n) {
    return (n < 10 ? "0" : "") + n;
  }
  return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
}

function hmwLog(msg) {
  try {
    var log = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HorizonMWHandler.log");
    System.IO.File.AppendAllText(log, "[" + hmwTimestamp() + "] " + msg + "\r\n");
  } catch (e) {}
}

// %LOCALAPPDATA%\hmw-mod of the real, non-Nucleus user profile.
function hmwRealAppData() {
  return System.Environment.GetEnvironmentVariable("LOCALAPPDATA") + "\\hmw-mod";
}

// Touched by both the handler and HMWConnectHotkey.ps1 to end the watcher early.
function hmwStopSentinel() {
  return System.IO.Path.Combine(System.IO.Path.GetTempPath(), "HMWConnectHotkey.stop");
}

function hmwEnsureDir(path) {
  if (!System.IO.Directory.Exists(path)) {
    System.IO.Directory.CreateDirectory(path);
  }
}

function hmwDelete(path) {
  try {
    if (System.IO.File.Exists(path)) {
      System.IO.File.Delete(path);
    }
  } catch (e) {
    hmwLog("delete failed: " + path + " -> " + e);
  }
}

// Copy only when the instance has no file yet, so player edits survive relaunch.
function hmwSeedFile(src, dst) {
  if (System.IO.File.Exists(dst)) {
    return;
  }
  if (System.IO.File.Exists(src)) {
    System.IO.File.Copy(src, dst, false);
  }
}

// Same, but fall back to a literal default when the source install has no copy.
function hmwSeedOrCreate(src, dst, fallback) {
  if (System.IO.File.Exists(dst)) {
    return;
  }
  if (System.IO.File.Exists(src)) {
    System.IO.File.Copy(src, dst, false);
  } else {
    System.IO.File.WriteAllText(dst, fallback);
  }
}

// Context.ReplaceLinesInTextFile silently drops writes for dvars that are not
// already present, so scan and append instead of relying on it.
function hmwSetCfgValue(path, key, value) {
  if (!System.IO.File.Exists(path)) {
    hmwLog("cfg missing, cannot set " + key + ": " + path);
    return;
  }
  var text = "" + System.IO.File.ReadAllText(path);
  var lines = text.split("\n");
  var newLine = key + ' "' + value + '"';
  var found = false;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/[\r\n]+$/, "");
    if (line.indexOf(key + " ") === 0) {
      lines[i] = newLine;
      found = true;
    } else {
      lines[i] = line;
    }
  }
  if (!found) {
    lines.push(newLine);
  }
  System.IO.File.WriteAllText(path, lines.join("\r\n"));
}

// Put the game in windowed mode so Nucleus can size each window to its slice.
// Without this every instance launches in borderless fullscreen, keeps rendering
// a full-screen backbuffer wherever Nucleus moves the window, and everything
// past the split boundary is cut off.
//
// HMW's FPS readout is cg_infobar_fps, NOT the stock cg_drawFPS.
//
// Established by toggling the counter in-game in one instance and diffing its
// config_mp.cfg against another instance's: cg_infobar_fps went to "1" while
// cg_drawFPS stayed "0" in both. Setting cg_drawFPS would have done nothing
// visible, and setting both risks two overlapping readouts.
//
// cg_drawFPSLabels is already "1" out of the box and is left alone. Note that
// "seta cg_drawFPS " is a prefix of "seta cg_drawFPSLabels ", so anything added
// here for the stock dvar has to keep hmwSetCfgValue's trailing space.
function hmwApplyFpsCounter(cfgPath) {
  if (!HMW_SHOW_FPS) {
    return false;
  }
  hmwSetCfgValue(cfgPath, "seta cg_infobar_fps", "1");
  return true;
}

// Sizing and positioning are left entirely to Nucleus, which is what
// Game.SupportsPositioning and Game.ResetWindows are for. In particular this
// does not write r_mode, and it resets vid_xpos and vid_ypos rather than aiming
// them at the slice:
//
//   r_mode only accepts a resolution the monitor enumerates. A split size such
//   as 2560x720 is not one (this display offers 23 modes and the only *x720 is
//   1280x720), so HMW silently reset r_mode to 2560x1440 in every instance and
//   writing it achieved nothing.
//
//   Because r_mode reverts to native, pre-positioning with vid_ypos put a
//   full-height 1440 window at y=720 on a 1440 tall screen, half of it off the
//   bottom of the display. That was the only value differing between the
//   instance that crashed during "reposition, resize and strip borders" and the
//   one that survived, so these are pinned back to the stock -1. Setting them
//   explicitly rather than skipping them matters: an instance configured by an
//   earlier version still has the bad value on disk, and HMW rewrites
//   config_mp.cfg on exit so it would otherwise persist.
//
// Called on every launch rather than only when players2 is seeded, for the same
// reason.
function hmwApplyWindowedMode(cfgPath) {
  hmwSetCfgValue(cfgPath, "seta r_fullscreen", "0");
  hmwSetCfgValue(cfgPath, "seta r_fullscreenWindow", "0");
  hmwSetCfgValue(cfgPath, "seta r_aspectRatio", "auto");
  // r_renderResolution is a megapixel count, "3.6864" for 2560x1440. Pin the
  // render resolution to the window instead of editing that number.
  hmwSetCfgValue(cfgPath, "seta r_renderResolutionNative", "1");
  hmwSetCfgValue(cfgPath, "seta vid_xpos", "-1");
  hmwSetCfgValue(cfgPath, "seta vid_ypos", "-1");
  return true;
}

// --- graphics presets ------------------------------------------------------

// Dvars a preset file is never allowed to set, however it has been edited.
// These are the ones the handler owns: let a preset put r_fullscreen back to "1"
// or pin vid_ypos at a slice offset and split-screen breaks or an instance
// crashes on reposition, and letting it set "name" would collapse every
// instance onto one player profile.
var HMW_PRESET_BLOCKED = [
  "r_fullscreen",
  "r_fullscreenWindow",
  "r_mode",
  "vid_xpos",
  "vid_ypos",
  "name"
];

function hmwPresetBlocked(dvar) {
  for (var i = 0; i < HMW_PRESET_BLOCKED.length; i++) {
    if (HMW_PRESET_BLOCKED[i].toLowerCase() === dvar.toLowerCase()) {
      return true;
    }
  }
  return false;
}

// Applies one preset file's seta lines to an instance's config, leaving every
// dvar the file does not mention untouched. That is the whole reason this reads
// a list of dvars instead of copying a prebuilt config over the top the way the
// stock MWR handler does: a wholesale copy would discard this instance's name,
// windowed mode and FPS setting, and the stock handler's configs use MWR's
// hashed dvar names, which HMW does not use.
//
// Returns the number of dvars applied, 0 for "Default", a missing file or an
// unrecognised preset name.
function hmwApplyGraphicsPreset(cfgPath, preset, presetDir) {
  if (!preset || preset === "Default") {
    return 0;
  }

  var path = presetDir + "\\" + preset + ".cfg";
  if (!System.IO.File.Exists(path)) {
    hmwLog("graphics preset '" + preset + "' has no file at " + path + ", leaving settings alone");
    return 0;
  }

  var lines = System.IO.File.ReadAllLines(path);
  var applied = 0;
  var malformed = 0;
  var skipped = [];

  for (var i = 0; i < lines.length; i++) {
    var line = ("" + lines[i]).replace(/^\s+|\s+$/g, "");
    if (line === "" || line.indexOf("//") === 0 || line.indexOf("#") === 0) {
      continue;
    }
    // seta <dvar> "<value>", or bare <dvar> <value>.
    //
    // Both forms are anchored and the dvar name is restricted, because a looser
    // pattern such as (\S+)\s+"?([^"]*)"? also swallows ordinary prose: a stray
    // line of English in a preset file parsed as a dvar named after its first
    // word and got written into config_mp.cfg. An unquoted value has to be a
    // single token for the same reason. Quoted values keep everything inside the
    // quotes, so string settings with spaces survive.
    var m = /^(?:seta\s+)?([A-Za-z0-9_]+)\s+"([^"]*)"\s*$/.exec(line);
    if (!m) {
      m = /^(?:seta\s+)?([A-Za-z0-9_]+)\s+(\S+)\s*$/.exec(line);
    }
    if (!m) {
      malformed++;
      continue;
    }
    var dvar = m[1];
    var value = m[2];
    if (hmwPresetBlocked(dvar)) {
      skipped.push(dvar);
      continue;
    }
    hmwSetCfgValue(cfgPath, "seta " + dvar, value);
    applied++;
  }

  hmwLog("graphics preset " + preset + ": applied " + applied + " dvar(s)" +
         (skipped.length ? ", ignored " + skipped.join(", ") + " (handler owns these)" : "") +
         (malformed ? ", skipped " + malformed + " unparseable line(s)" : ""));
  return applied;
}

// --- identity backup / restore --------------------------------------------
// The handler rewrites files that belong to the user's normal HMW install, so
// keep a pristine copy of each before the first modification.

function hmwBackupIdentityOnce() {
  var dir = hmwRealAppData();
  for (var i = 0; i < HMW_IDENTITY_FILES.length; i++) {
    var live = dir + "\\" + HMW_IDENTITY_FILES[i];
    var bak = live + HMW_BACKUP_SUFFIX;
    if (System.IO.File.Exists(live) && !System.IO.File.Exists(bak)) {
      System.IO.File.Copy(live, bak, false);
      hmwLog("backed up " + live);
    }
  }
}

// Idempotent: safe to call from Game.OnStop and from the watcher script.
function hmwRestoreIdentity() {
  var dir = hmwRealAppData();
  for (var i = 0; i < HMW_IDENTITY_FILES.length; i++) {
    var live = dir + "\\" + HMW_IDENTITY_FILES[i];
    var bak = live + HMW_BACKUP_SUFFIX;
    try {
      if (System.IO.File.Exists(bak)) {
        System.IO.File.Copy(bak, live, true);
        System.IO.File.Delete(bak);
        hmwLog("restored " + live);
      }
    } catch (e) {
      hmwLog("restore failed: " + live + " -> " + e);
    }
  }
}

// The pristine hwgd.pf written by HMW is 38 ASCII characters plus a single 0x00
// terminator, 39 bytes total. HMW reads it into a fixed size buffer, so a short
// write causes a buffer overread. Keep the byte count and the terminator exact.
function hmwWriteGuid(path, guid) {
  System.IO.File.WriteAllText(path, guid + "\u0000");
  try {
    var len = new System.IO.FileInfo(path).Length;
    if (len != 39) {
      hmwLog("WARNING hwgd.pf is " + len + " bytes, expected 39: " + path);
    }
  } catch (e) {}
}

// ---------------------------------------------------------------------------
// Game definition
// ---------------------------------------------------------------------------

Game.GameName = "HorizonMW";
Game.GUID = "HorizonMW";
Game.SteamID = "393080";
Game.MaxPlayers = 8;
Game.MaxPlayersOneMonitor = 8;
Game.HandlerInterval = 100;

// --- Nucleus UI options ----------------------------------------------------

// Graphics preset, so settings can be dropped when running 4 instances and
// raised again for 2. Picked in Nucleus under the game's options menu, and read
// back in Play() as Context.Options["Graphics"].
//
// "Default" is first, which makes it the default selection, and it changes
// nothing at all: whatever each instance already has is left alone.
//
// Each other entry is a plain text file of seta lines under
// handlers\HorizonMW\Graphics. They are meant to be edited. HMW has no single
// master quality dvar, and several of its graphics dvars are string enums
// (sm_tileResolution "High", r_postAA "None", r_depthPrepass "All") whose other
// accepted values are not documented anywhere, so the shipped presets only touch
// dvars whose type and direction are unambiguous. Guessing at a value the game
// does not accept is what made r_mode silently revert to native and, through
// that, put a window half off-screen.
//
// To build a preset that is guaranteed valid, set the graphics you want in-game
// and run Capture-GraphicsPreset.ps1, which copies the real values out of that
// instance's config.
//
// This has to stay below the "Game definition" marker: the test harness executes
// everything above that marker under a bare Jint engine with no Game object.
var HMW_GRAPHICS_PRESETS = ["Default", "Low", "Medium", "High", "Extra"];
Game.AddOption(
  "Graphics preset for every instance",
  "Lower this when running more instances. Default leaves each instance's own settings alone. Presets are editable text files in handlers\\HorizonMW\\Graphics.",
  "Graphics",
  HMW_GRAPHICS_PRESETS
);

// hmw-mod.exe is both launcher and game process. Game.LauncherExe is left unset
// on purpose: if LauncherExe and ExecutableName name the same binary, Nucleus
// starts a process then searches by name for a process to attach to, which is
// ambiguous as soon as a second instance exists. Unset means Nucleus keeps the
// process it actually started.
Game.ExecutableName = "hmw-mod.exe";
Game.LauncherExeIgnoreFileCheck = true;
Game.BinariesFolder = "";

Game.SymlinkGame = true;
Game.SymlinkExe = false; // each instance needs a real copy; HMW writes next to the exe and self-updates
Game.SymlinkFolders = false;
Game.KeepSymLinkOnExit = true;

Game.DirSymlinkExclusions = ["hmw-mod", "players2"];
Game.FileSymlinkExclusions = [
  "hmw-mod.exe",
  "config_mp.cfg",
  "keys_mp.cfg",
  "settings_c.zip.h1",
  "settings_m.zip.h1",
  "favourites.json",
  "history.json",
  "hmwcdta",
  "hmwdta",
  "language",
  "upshd.dat",
  "commondata",
  "mpdata"
];
Game.FileSymlinkCopyInstead = [
  "steam_api.dll",
  "steam_api.ini",
  "steam_api64.dll",
  "Steam.dll",
  "SteamAPIUpdater.dll",
  "steamclient.dll",
  "XGamepad.dll",
  "h1_sp64_ship.exe"
];

Game.NeedsSteamEmulation = false;
Game.UseGoldberg = false;
Game.LaunchAsDifferentUsers = false;

// Instances are separated by UDP port, not by bind address. ForceBindIP would
// pin each instance to a specific local IP and the guests' "connect
// 127.0.0.1:27016" would no longer reach the host.
Game.UseForceBindIP = false;

// Per-instance %LOCALAPPDATA%\hmw-mod. Not sufficient on its own (see Game.Play),
// but harmless and keeps Nucleus' config tooling pointed at the right folder.
Game.UserProfileConfigPath = "AppData\\Local\\hmw-mod";
Game.UserProfileConfigPathNoCopy = true;

Game.SupportsPositioning = true;
Game.ForceFinishOnPlay = false;
Game.HasDynamicWindowTitle = false;
Game.DontResize = false;
Game.DontRemoveBorders = false;
Game.DontReposition = false;
Game.ResetWindows = true;
Game.RefreshWindowAfterStart = true;
Game.SetForegroundWindowElsewhere = true;
Game.SetWindowHook = true;
Game.ProcessChangesAtEnd = false;
Game.HideTaskbar = true;
Game.PreventWindowDeactivation = false;
Game.KeyboardPlayerSkipPreventWindowDeactivate = false;

// Also decides how much time the LAST instance gets before Nucleus repositions
// it. Every other instance is repositioned when the next one is grabbed, so it
// gets PauseBetweenStarts + PauseBetweenProcessGrab of grace, but the last one
// is repositioned immediately in "final preperations". At 10 that gave instance
// 1 only 28 s from launch to resize while instance 0 had 45 s, and instance 1
// crashed mid-resize with a C++ exception while still initialising. 25 puts the
// last instance at roughly the same 43 s.
Game.PauseBetweenStarts = 25;

// How long Nucleus waits after launching before it grabs the process, injects
// ProtoInput and repositions the window. The base MWR handler needs 30 because
// h1-mod.exe has to spawn a separate h1_mp64_ship.exe; hmw-mod.exe is the game
// process from the start, so it does not need anywhere near that long, and 30
// left the windows sitting unpositioned for half a minute. Raise this again if
// an instance gets grabbed before its window exists.
Game.PauseBetweenProcessGrab = 15;

Game.StartArguments = "-nosteam -multiplayer";
Game.KillProcessesOnClose = [];

// Legacy hooks: all off, ProtoInput does the input work.
Game.Hook.ForceFocus = false;
Game.Hook.ForceFocusWindowName = "Call of Duty®: Modern Warfare® Remastered Multiplayer";
Game.FakeFocus = false;
Game.HookFocus = false;
Game.BlockRawInput = false;
Game.Hook.DInputEnabled = false;
Game.Hook.DInputForceDisable = true;
Game.Hook.XInputEnabled = false;
Game.Hook.XInputReroute = false;
Game.InjectHookXinput = false;
Game.Hook.CustomDllEnabled = false;
Game.Hook.UseAlpha8CustomDll = false;

Game.Description =
  "HorizonMW split-screen.\n\nSetup: launch every instance, wait until they have all finished resizing and repositioning.\n\nJoining: on instance 1 (top-left) host a private/custom match, then press F2 once. Every other instance is sent 'connect 127.0.0.1:27016' through its console and joins the host.\n\nEach instance binds its own port (27016, 27018, 27020, ...) and gets its own players2 folder, so settings and unlocks no longer overwrite each other. Instance 1 plays on your real HorizonMW account; the other instances run anonymously, otherwise the HMW server sees one account logging in several times and the instances kick each other.\n\nYour real HorizonMW identity files in %LOCALAPPDATA%\\hmw-mod (hwgd.pf, hmw-key, hmw-key.pub) are backed up as *.nucleus-original before the session and restored when the session ends. If Nucleus is killed hard, launching once more and closing normally restores them.\n\nIf you use keyboards and mice, press END once after all instances are positioned to lock input so each instance gets its own cursor and keyboard. Press END again to unlock. F2 only works while input is unlocked.";

// --- USS deprecated options (kept off) -------------------------------------

Game.HookSetCursorPos = false;
Game.HookGetCursorPos = false;
Game.HookGetKeyState = false;
Game.HookGetAsyncKeyState = false;
Game.HookGetKeyboardState = false;
Game.HookFilterRawInput = false;
Game.HookFilterMouseMessages = false;
Game.HookUseLegacyInput = false;
Game.HookDontUpdateLegacyInMouseMsg = false;
Game.HookMouseVisibility = false;

Game.SendNormalMouseInput = false;
Game.SendNormalKeyboardInput = false;
Game.SendScrollWheel = false;
Game.ForwardRawKeyboardInput = false;
Game.ForwardRawMouseInput = false;
Game.HookReRegisterRawInput = false;
Game.HookReRegisterRawInputMouse = false;
Game.HookReRegisterRawInputKeyboard = false;
Game.DrawFakeMouseCursor = false;

// --- ProtoInput ------------------------------------------------------------

Game.SupportsMultipleKeyboardsAndMice = true;

// Injection method. The base MWR handler uses the stealth method, which
// ProtoInput's own readme describes as the last resort for games that actively
// block injection. Against hmw-mod.exe it killed the second instance: that
// process died 30.5 s after launch (PauseBetweenProcessGrab was 30) with an
// access violation inside ntdll.dll and no ProtoInput module in its loaded
// module list, i.e. the injection itself faulted, and Nucleus reported
// "ProtoInput failed to runtime inject". EasyHook runtime injection is the
// documented default and is what ProtoInput recommends trying first.
//
// If injection still fails, these four lines are the knob: enable exactly one.
// Order to try: EasyHookMethod, RemoteLoadMethod, InjectStartup, EasyHookStealthMethod.
Game.ProtoInput.InjectStartup = false;
Game.ProtoInput.InjectRuntime_RemoteLoadMethod = false;
Game.ProtoInput.InjectRuntime_EasyHookMethod = true;
Game.ProtoInput.InjectRuntime_EasyHookStealthMethod = false;

Game.LockInputAtStart = false;
Game.LockInputSuspendsExplorer = true;
Game.ProtoInput.FreezeExternalInputWhenInputNotLocked = true;
Game.LockInputToggleKey = 0x23; // END

Game.ProtoInput.RenameHandlesHook = false;
Game.ProtoInput.RenameHandles = [];
Game.ProtoInput.RenameNamedPipes = [];

Game.ProtoInput.RegisterRawInputHook = false;
Game.ProtoInput.GetRawInputDataHook = false;
Game.ProtoInput.MessageFilterHook = false;
Game.ProtoInput.GetCursorPosHook = false;
Game.ProtoInput.SetCursorPosHook = false;
Game.ProtoInput.GetKeyStateHook = false;
Game.ProtoInput.GetAsyncKeyStateHook = false;
Game.ProtoInput.GetKeyboardStateHook = false;
Game.ProtoInput.CursorVisibilityHook = false;
Game.ProtoInput.ClipCursorHook = true;
Game.ProtoInput.FocusHooks = true;
Game.ProtoInput.ClipCursorHookCreatesFakeClip = true;

Game.ProtoInput.RawInputFilter = false;
Game.ProtoInput.MouseMoveFilter = false;
Game.ProtoInput.MouseActivateFilter = false;
Game.ProtoInput.WindowActivateFilter = false;
Game.ProtoInput.WindowActvateAppFilter = false;
Game.ProtoInput.MouseWheelFilter = false;
Game.ProtoInput.MouseButtonFilter = false;
Game.ProtoInput.KeyboardButtonFilter = false;

Game.ProtoInput.SendMouseWheelMessages = true;
Game.ProtoInput.SendMouseButtonMessages = true;
Game.ProtoInput.SendMouseMovementMessages = true;
Game.ProtoInput.SendKeyboardButtonMessages = true;

Game.ProtoInput.XinputHook = true;

// Nucleus only ships a 32-bit openxinput1_3.dll and hmw-mod.exe is 64-bit, so
// that DLL can never load. On Windows 11 the failed load faults inside ntdll's
// Switchback path instead of returning an error and kills the game about a
// second after ProtoInput injects, i.e. PauseBetweenProcessGrab seconds after
// launch. Verified against the PE header of
// C:\NucleusCoop\openxinput1_3.dll (machine 0x14C, x86) versus
// hmw-mod.exe (machine 0x8664, x64). Standard XInput caps at 4 pads, which is
// the practical limit anyway. Do not also enable XInputPlus: doubling up the
// restriction breaks wireless controllers.
Game.ProtoInput.UseOpenXinput = false;

Game.ProtoInput.OnInputLocked = function () {
  for (var i = 0; i < PlayerList.Count; i++) {
    var player = PlayerList[i];

    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetCursorPosHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.SetCursorPosHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetKeyStateHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetAsyncKeyStateHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetKeyboardStateHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.CursorVisibilityStateHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetRawInputDataHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.RegisterRawInputHookID);
    ProtoInput.InstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.MessageFilterHookID);

    //Avoid the mouse move filter unless absolutely necessary as it can massively affect performance if the game gets primary input from mouse move messages
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseMoveFilterID);

    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.RawInputFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseActivateFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.WindowActivateFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.WindowActivateAppFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseWheelFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseButtonFilterID);
    ProtoInput.EnableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.KeyboardButtonFilterID);

    ProtoInput.SetDrawFakeCursor(player.ProtoInputInstanceHandle, false);
  }
};

Game.ProtoInput.OnInputUnlocked = function () {
  for (var i = 0; i < PlayerList.Count; i++) {
    var player = PlayerList[i];

    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetCursorPosHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.SetCursorPosHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetKeyStateHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetAsyncKeyStateHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetKeyboardStateHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.CursorVisibilityStateHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.GetRawInputDataHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.RegisterRawInputHookID);
    ProtoInput.UninstallHook(player.ProtoInputInstanceHandle, ProtoInput.Values.MessageFilterHookID);

    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseMoveFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.RawInputFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseActivateFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.WindowActivateFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.WindowActivateAppFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseWheelFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.MouseButtonFilterID);
    ProtoInput.DisableMessageFilter(player.ProtoInputInstanceHandle, ProtoInput.Values.KeyboardButtonFilterID);

    ProtoInput.SetDrawFakeCursor(player.ProtoInputInstanceHandle, false);
  }
};

// ---------------------------------------------------------------------------
// Per-instance setup, runs once per instance immediately before it launches
// ---------------------------------------------------------------------------

Game.Play = function () {
  var instFolder = Context.GetFolder(Nucleus.Folder.InstancedGameFolder);
  var playerNo = Context.PlayerID + 1;

  hmwLog("=== Play() instance " + Context.PlayerID + " -> " + instFolder);

  // -- 1. real copy of the executable ---------------------------------------
  // HMW writes next to hmw-mod.exe and self-updates, so a symlink is not enough.
  var exeOrigin = System.IO.Path.Combine(Context.RootInstallFolder, "hmw-mod.exe");
  var exeTarget = instFolder + "\\hmw-mod.exe";
  System.IO.File.Copy(exeOrigin, exeTarget, true);

  // -- 2. unique network port ----------------------------------------------
  // The engine uses net_port and net_port+1, hence the step of 2. Guests always
  // connect to the host's port, HMW_HOST_PORT.
  var args = "-nosteam -multiplayer +set net_port " + (HMW_HOST_PORT + Context.PlayerID * 2);
  Game.StartArguments = args;
  Context.StartArguments = args;
  hmwLog("args: " + args);

  // -- 3. save isolation: per-instance players2 ------------------------------
  var srcP2 = Context.RootInstallFolder + "\\players2";
  var players2 = instFolder + "\\players2";
  var users = players2 + "\\user";
  hmwEnsureDir(players2);
  hmwEnsureDir(users);

  hmwSeedFile(srcP2 + "\\config_mp.cfg", players2 + "\\config_mp.cfg");
  hmwSeedFile(srcP2 + "\\keys_mp.cfg", players2 + "\\keys_mp.cfg");
  hmwSeedFile(srcP2 + "\\settings_c.zip.h1", players2 + "\\settings_c.zip.h1");
  hmwSeedFile(srcP2 + "\\settings_m.zip.h1", players2 + "\\settings_m.zip.h1");

  // These four must exist or HMW can stall on first launch.
  hmwSeedOrCreate(srcP2 + "\\favourites.json", players2 + "\\favourites.json", "[]");
  hmwSeedOrCreate(srcP2 + "\\history.json", players2 + "\\history.json", "[]");
  hmwSeedOrCreate(srcP2 + "\\user\\hmwcdta", users + "\\hmwcdta", "");
  hmwSeedOrCreate(srcP2 + "\\user\\hmwdta", users + "\\hmwdta", "");

  // -- 4. distinct in-game name ---------------------------------------------
  hmwSetCfgValue(players2 + "\\config_mp.cfg", "seta name", "Player" + playerNo);

  // -- 4b. windowed mode, so Nucleus can size the window to the slice --------
  hmwApplyWindowedMode(players2 + "\\config_mp.cfg");
  hmwApplyFpsCounter(players2 + "\\config_mp.cfg");

  // -- 4c. graphics preset chosen in the Nucleus options menu ----------------
  // Applied last so a preset can override the render settings written above,
  // for example turning r_renderResolutionNative off and scaling the render
  // resolution down. It cannot touch the window or identity dvars: see
  // HMW_PRESET_BLOCKED.
  hmwApplyGraphicsPreset(
    players2 + "\\config_mp.cfg",
    Context.Options["Graphics"],
    Context.ScriptFolder + "\\Graphics"
  );
  hmwLog("windowed; Nucleus slice " + Context.Width + "x" + Context.Height +
    " at " + Context.PosX + "," + Context.PosY);

  // -- 5. identity isolation -------------------------------------------------
  // HMW identifies a player by %LOCALAPPDATA%\hmw-mod\hwgd.pf. If every instance
  // reports the same GUID the HMW server treats them as one player connecting
  // repeatedly and they kick each other off.
  var realAppData = hmwRealAppData();
  hmwEnsureDir(realAppData);
  hmwBackupIdentityOnce();

  // Context.EnvironmentPlayer is empty unless a Nucleus environment is in use,
  // so never build a path from it blindly.
  var envPlayer = "" + (Context.EnvironmentPlayer || "");
  var nucleusAppData = null;
  if (envPlayer.length > 2 && envPlayer.indexOf(":\\") === 1) {
    nucleusAppData = envPlayer + "\\AppData\\Local\\hmw-mod";
    hmwEnsureDir(nucleusAppData);
  } else {
    hmwLog("no Nucleus environment path, using the real profile only");
  }

  // Single digit index, so this scheme caps at 9 players. Widen the format if
  // Game.MaxPlayers ever goes above 9. The 4 and the 8 keep it a well-formed
  // v4 GUID, which the HMW server validates.
  if (playerNo > 9) {
    hmwLog("ERROR player " + playerNo + " exceeds the single digit GUID scheme");
  }
  var playerGuid = "{00000000-0000-4000-8000-00000000000" + playerNo + "}";

  // Nucleus implements UserProfileConfigPath by temporarily rewriting
  // HKCU\...\Explorer\User Shell Folders, and HMW resolves its data path in a
  // way that can still land on the real %LOCALAPPDATA%, so write both. Writing
  // the shared location works because Nucleus staggers starts by
  // PauseBetweenStarts seconds and each instance reads it during its own
  // startup window.
  if (nucleusAppData) {
    hmwWriteGuid(nucleusAppData + "\\hwgd.pf", playerGuid);
  }
  hmwWriteGuid(realAppData + "\\hwgd.pf", playerGuid);
  hmwLog("guid " + playerGuid);

  // Only the host authenticates with the real account; guests run anonymously,
  // otherwise the server sees one account logging in several times.
  var liveKey = realAppData + "\\hmw-key";
  var livePub = realAppData + "\\hmw-key.pub";
  if (Context.PlayerID === 0) {
    var bakKey = liveKey + HMW_BACKUP_SUFFIX;
    var bakPub = livePub + HMW_BACKUP_SUFFIX;
    if (System.IO.File.Exists(bakKey)) {
      System.IO.File.Copy(bakKey, liveKey, true);
    }
    if (System.IO.File.Exists(bakPub)) {
      System.IO.File.Copy(bakPub, livePub, true);
    }
    if (nucleusAppData) {
      if (System.IO.File.Exists(liveKey)) {
        System.IO.File.Copy(liveKey, nucleusAppData + "\\hmw-key", true);
      }
      if (System.IO.File.Exists(livePub)) {
        System.IO.File.Copy(livePub, nucleusAppData + "\\hmw-key.pub", true);
      }
    }
    hmwLog("host keypair in place");
  } else {
    hmwDelete(liveKey);
    hmwDelete(livePub);
    if (nucleusAppData) {
      hmwDelete(nucleusAppData + "\\hmw-key");
      hmwDelete(nucleusAppData + "\\hmw-key.pub");
    }
    hmwLog("guest runs anonymously");
  }

  // -- 6. F2 host-join watcher, host instance only ---------------------------
  if (Context.PlayerID === 0) {
    hmwDelete(hmwStopSentinel());
    var hotkey = Context.ScriptFolder + "\\HMWConnectHotkey.bat";
    if (System.IO.File.Exists(hotkey)) {
      Context.RunAdditionalFiles([hotkey], false, 0);
      hmwLog("started " + hotkey);
    } else {
      hmwLog("WARNING hotkey watcher missing: " + hotkey);
    }
  }

  // -- 7. controllers --------------------------------------------------------
  // Carried over from the base MWR handler. Play() runs immediately before each
  // instance launches, so the assignment in effect at injection time is that
  // instance's own gamepad.
  for (var i = 0; i < PlayerList.Count; i++) {
    var player = PlayerList[i];
    player.ProtoController1 = Context.GamepadId;
    player.ProtoController2 = Context.GamepadId;
    player.ProtoController3 = Context.GamepadId;
    player.ProtoController4 = Context.GamepadId;
    player.ProtoController5 = Context.GamepadId;
    player.ProtoController6 = Context.GamepadId;
    player.ProtoController7 = Context.GamepadId;
    player.ProtoController8 = Context.GamepadId;
    player.ProtoController9 = Context.GamepadId;
  }
};

// ---------------------------------------------------------------------------
// Teardown. Player 1's launch deletes the account keypair, so without this HMW
// would generate a brand new keypair on the next normal start and silently
// replace the user's real identity.
// ---------------------------------------------------------------------------

Game.OnStop = function () {
  hmwLog("=== OnStop, restoring identity");
  try {
    System.IO.File.WriteAllText(hmwStopSentinel(), "stop");
  } catch (e) {}
  hmwRestoreIdentity();
};
