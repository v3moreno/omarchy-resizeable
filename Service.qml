import QtQuick
import Quickshell
import Quickshell.Io

// Service plugin: while enabled, keeps a generated drop-in in
// ~/.local/state/omarchy/toggles/hypr/ so Hyprland's resize_on_border stays on
// (Omarchy's default looknfeel.lua sets it off explicitly). On disable/remove
// the drop-in is deleted and Hyprland reloaded, restoring the default.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string dropinDirectory: Quickshell.env("HOME") + "/.local/state/omarchy/toggles/hypr"
  readonly property string dropinPath: dropinDirectory + "/omarchy-resizable.lua"
  // The drop-in also gates itself on the plugin id still being listed in
  // shell.json, so a drop-in that somehow outlives disable/remove is inert on
  // the next Hyprland reload instead of silently leaving the feature on.
  // The id is duplicated in manifest.json; keep them in sync. The whole body
  // is pcall'd: a toggle file that throws would abort the rest of the
  // Hyprland config load, so failure must degrade to "feature off".
  readonly property string dropinContent:
    "-- omarchy-resizable: generated, do not edit\n" +
    "pcall(function()\n" +
    "  local paths_ok, paths = pcall(require, \"default.hypr.paths\")\n" +
    "  local config_home = paths_ok and paths.config_home\n" +
    "    or (os.getenv(\"HOME\") .. \"/.config\")\n" +
    "  local f = io.open(config_home .. \"/omarchy/shell.json\", \"r\")\n" +
    "  local enabled = false\n" +
    "  if f then\n" +
    "    enabled = (f:read(\"*a\") or \"\"):find('\"id\"%s*:%s*\"omarchy%-resizable%.resizable\"') ~= nil\n" +
    "    f:close()\n" +
    "  end\n" +
    "  if enabled then\n" +
    "    hl.config({ general = { resize_on_border = true } }) -- omarchy-resizable\n" +
    "  end\n" +
    "end)\n"

  readonly property int hyprctlTimeoutMs: 5000

  // idle -> directories -> probe -> (ready | write -> reload -> verify -> borders -> ready | failed)
  property string phase: "idle"
  property bool directoriesReady: false
  property bool liveKnown: false
  property bool liveValue: false
  property bool dropinKnown: false
  property string dropinExisting: ""
  property var hyprctlContinuation: null
  property string hyprctlDescription: ""

  function notify(summary, body) {
    if (notifier.running) return
    notifier.command = ["notify-send", "-a", "Omarchy Resizable", summary, body]
    notifier.running = true
  }

  function fail(message) {
    phase = "failed"
    console.warn("omarchy-resizable: " + message)
    notify("Border resize could not be enabled", message)
  }

  function parseJson(text, description) {
    try {
      return JSON.parse(text)
    } catch (error) {
      fail("hyprctl " + description + " did not return JSON: " + error.message)
      return null
    }
  }

  function runHyprctl(args, description, nextPhase, continuation) {
    if (hyprctlProcess.running) {
      fail("Could not start hyprctl " + description + ".")
      return
    }
    phase = nextPhase
    hyprctlDescription = description
    hyprctlContinuation = continuation
    hyprctlProcess.command = ["hyprctl"].concat(args)
    hyprctlProcess.running = true
    hyprctlWatchdog.restart()
  }

  function begin() {
    phase = "directories"
    mkdirProcess.command = ["mkdir", "-p", dropinDirectory]
    mkdirProcess.running = true
    runHyprctl(["-j", "getoption", "general:resize_on_border"],
      "getoption resize_on_border", "probe", gotLiveValue)
  }

  function gotLiveValue(text) {
    var data = parseJson(text, "getoption resize_on_border")
    if (!data) return
    liveValue = data.bool === true
    liveKnown = true
    maybeWriteDropin()
  }

  function maybeWriteDropin() {
    if (phase !== "directories" && phase !== "probe") return
    if (!directoriesReady || !liveKnown || !dropinKnown) return
    // Already applied and persisted: leave Hyprland untouched. This is what
    // keeps an omarchy-shell restart side-effect-free.
    if (liveValue && dropinExisting === dropinContent) {
      phase = "ready"
      return
    }
    phase = "write"
    dropinFile.setText(dropinContent)
  }

  function dropinSaved() {
    runHyprctl(["reload"], "reload", "reload", function() {
      runHyprctl(["-j", "getoption", "general:resize_on_border"],
        "getoption resize_on_border", "verify", verified)
    })
  }

  function verified(text) {
    var data = parseJson(text, "getoption resize_on_border")
    if (!data) return
    if (data.bool !== true) {
      fail("Hyprland still reports resize_on_border off after reload.")
      return
    }
    // border_size = 0 silently disables border resize (no grab area).
    runHyprctl(["-j", "getoption", "general:border_size"],
      "getoption border_size", "borders", bordersChecked)
  }

  function bordersChecked(text) {
    var data = parseJson(text, "getoption border_size")
    if (!data) return
    phase = "ready"
    if (typeof data.int === "number" && data.int <= 0) {
      notify("Border resize is on, but borders are 0px",
        "resize_on_border needs general:border_size > 0 to grab a window edge.")
    }
  }

  Component.onCompleted: root.begin()

  // Reached on `omarchy plugin disable` / `plugin remove` (the shell calls
  // destroy()) and on shell exit. Children are already gone by the time this
  // runs (id lookups throw ReferenceError), so cleanup goes through the
  // Quickshell singleton: execDetached spawns now and disowns the child.
  // Remove the drop-in, then reload so resize_on_border falls back to the
  // Omarchy default.
  Component.onDestruction: {
    Quickshell.execDetached(["sh", "-c",
      "rm -f -- \"$1\" && hyprctl reload >/dev/null 2>&1 || :",
      "omarchy-resizable-cleanup", dropinPath])
  }

  Process {
    id: mkdirProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.fail("Could not create " + root.dropinDirectory + ".")
        return
      }
      root.directoriesReady = true
      root.maybeWriteDropin()
    }
  }

  Process {
    id: hyprctlProcess
    stdout: StdioCollector { id: hyprctlStdout; waitForEnd: true }
    stderr: StdioCollector { id: hyprctlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      hyprctlWatchdog.stop()
      var continuation = root.hyprctlContinuation
      root.hyprctlContinuation = null
      if (exitCode !== 0) {
        root.fail("hyprctl " + root.hyprctlDescription + " failed" +
          (hyprctlStderr.text ? ": " + String(hyprctlStderr.text).trim() : "."))
        return
      }
      if (continuation) continuation(String(hyprctlStdout.text || ""))
    }
  }

  FileView {
    id: dropinFile
    path: root.dropinPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.dropinExisting = text()
      root.dropinKnown = true
      root.maybeWriteDropin()
    }
    onLoadFailed: {
      root.dropinExisting = ""
      root.dropinKnown = true
      root.maybeWriteDropin()
    }
    onSaved: if (root.phase === "write") root.dropinSaved()
    onSaveFailed: root.fail("Could not save the generated drop-in.")
  }

  Process { id: notifier }

  Timer {
    id: hyprctlWatchdog
    interval: root.hyprctlTimeoutMs
    repeat: false
    onTriggered: {
      if (!hyprctlProcess.running) return
      hyprctlProcess.signal(9)
      root.fail("hyprctl " + root.hyprctlDescription + " did not answer within "
        + root.hyprctlTimeoutMs + "ms; Hyprland IPC may be wedged.")
    }
  }
}
