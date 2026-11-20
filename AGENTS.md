# AGENTS.md

Guidance for AI agents (and humans) changing this repo. It records the *why* behind
choices that aren't obvious from the code. Read README.md first for what this is.

## Hard rule: no Superwhisper binaries in git or in the bundle

Superwhisper is proprietary. This repo and its published bundles contain only our
packaging: the launcher, host shims, desktop files and metainfo, plus two open-source
libraries built from source (gtk4-layer-shell, wl-clipboard). Upstream's release archive
is an **extra-data** source. flatpak downloads it from `tux.superwhisper.com` on the
user's machine and checks its sha256 and size; `apply_extra` then unpacks it into
`/app/extra`.

- The only upstream files in the bundle are the app icon PNGs. The build copies them from
  the verified archive so launchers show an icon; flatpak can't export icons from
  `/app/extra`.
- `scripts/build-flatpak.sh` fails if upstream binaries end up in the bundle. Keep that check.
- `dist/`, `.work/`, `.cache/` (upstream archives) and `.flatpak-user/` are git-ignored.
  Never commit them.
- The extra-data URL must be the **versioned** archive URL
  (`…/<arch>/v<ver>/superwhisper-omarchy-<arch>-<ver>.tar.zst`). Users install from it for
  as long as that build is published. `upstream.py` refuses an unversioned URL.
- A bundle with extra-data can't be installed from the file ("Extra data missing in
  detached metadata"). Install it from a repo; README → *Build locally* shows how.

## Update flow

`scripts/upstream.py` is the trust anchor, ported from vintoware-rpm's
`packages/superwhisper/update`. It reads `stable.json` and checks the archive's size and
sha256 against it. It also checks the minisign signature against
`manifest/superwhisper-release.pub`, which is upstream's Linux release key and is also
embedded in the archive as `app/assets/linux-release.pub`. Only then do the URL, sha256
and size go into the manifest. At install time flatpak re-checks the sha256, and
`apply_extra` checks every file against the archive's `MANIFEST.sha256`.

CI saves `stable.json` once in the `check` job and gives the same file to both arch
builds, so an upstream release between the jobs can't produce mismatched bundles.

The published version is `<superwhisper version>-<PKG_REVISION>` (`build.env`). Bump
`PKG_REVISION` to ship a packaging change. The push to main then rebuilds, because the
version no longer matches the pointer files in flatpak-repo.

## Sandbox model: host systemd, on purpose

Upstream is built around a **systemd user service** (`superwhisper daemon`), driven with
`systemctl --user`: start from Settings, is-active checks, and "launch at login" as
enable/disable. It also uses host tools: KWin scripting, kreadconfig6, busctl (lock
screen) and WirePlumber. We keep upstream's behaviour rather than reimplement it, so the
sandbox is **not** a security boundary:

- `--socket=session-bus` covers `flatpak-spawn --host`, KWin scripting, kglobalaccel,
  MPRIS, notifications and `org.a11y.Bus`. The Slack flatpak has the same access.
- `/app/bin/{systemctl,busctl,kreadconfig5,kreadconfig6,kwriteconfig6,hyprctl,gsettings,wtype,ydotool,pgrep,wireplumber,fc-cache}`
  are symlinks to `host-command`, which runs the real command on the host. `pgrep` is
  forwarded because the sandbox has its own PID namespace (doctor checks the host's fcitx5).

### The host unit (`manifest/files/superwhisper-flatpak.service`)

- `ensure-service` (run by the launcher for every command except the unit's own) writes
  the units (the daemon's, plus the fcitx5 pair below) to `~/.config/systemd/user/`. It re-writes it and runs `daemon-reload` when
  the copy in `/app` changes, and enables it on first install, like the RPM's preset.
  When the app is opened from the launcher (`settings`), it also starts the unit.
  `SW_SERVICE_UNIT=superwhisper-flatpak.service` tells upstream the unit's name.
- **flatpak moves the sandbox into its own `app-flatpak-<id>-<n>.scope`.** systemd then
  tracks only the outer `bwrap` (MainPID); the service cgroup shows `Tasks: 0`.
  Stopping MainPID alone **orphans the daemon and its workers** (tested). So `ExecStop`
  reads the scope from `/proc/$MAINPID/cgroup` and stops it, which sends SIGTERM to
  everything in the sandbox. `--die-with-parent` covers the outer process dying any other way.
  `Restart=on-failure` works: the daemon's exit status passes through bwrap (tested with
  SIGKILL).
- For the same reason, the daemon's output is logged under the scope unit, not the
  service. `SyslogIdentifier=superwhisper-flatpak` gives it a stable tag:
  `journalctl --user -t superwhisper-flatpak`.
- **One daemon only.** Upstream's own guard only knows `superwhisper.service` and
  `superwhisper-dev.service`, and doesn't fire across them. With both running, F9
  triggered two dictations (tested). The unit is ordered `After=` the native units, and its
  `ExecCondition` skips it while either is active. `ensure-service` shows a notification
  in that case. Don't use `Conflicts=` instead: with both enabled, the login transaction
  would contain conflicting jobs.
- `ExecCondition` also checks `flatpak info`, so the unit is skipped, not failed, after
  `flatpak uninstall`.

### Muffle is unsupported (`/app/bin/systemd-run` refuses)

Upstream starts Muffle's PipeWire filter with `systemd-run --user --unit=superwhisper-muffle …`
and an `ExecStop=` that names a sandbox path. We tried wrapping the command in
`flatpak run`. The filter loaded into WirePlumber, but the daemon stopped it within
~25 ms: the transient unit's MainPID is `flatpak run`'s bwrap, not the filter process
PipeWire sees. The shim now fails up front, and the daemon falls back to lowering other
apps' volume with `pactl`. Muffle is opt-in (`defaultPlaybackBehavior`; default `pause`).

## Paths

`env.sh`, sourced by the launcher:
- `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` point at the host defaults.
  finish-args mount only the `superwhisper/` subdirectories. Also mounted:
  `~/.config/wireplumber` and `~/.config/systemd/user`, both written for the host. So
  settings, history and the multi-GB models are shared with the RPM or upstream's
  installer. `XDG_CACHE_HOME` stays in the sandbox, which keeps Mesa's shader cache
  writable. finish-args spell the state dir `~/.local/state/…`: flatpak 1.16 rejects
  `xdg-state/…`.
- `SUPERWHISPER_RUNTIME=$XDG_RUNTIME_DIR/app/$FLATPAK_ID/superwhisper`. Each `flatpak run`
  gets a private `/run/user/$UID`. `app/$FLATPAK_ID` is the one directory every instance
  shares (daemon, Settings, CLI `status`; tested). It is also bind-mounted at the same path
  on the host, where KWin reads the focus script (`kwin-focus.js`) by path.
- `SW_INDICATOR_BIN=/app/libexec/superwhisper-flatpak/indicator`. The indicator's tray
  item gives the host shell its icon as a **file path** under
  `$XDG_RUNTIME_DIR/superwhisper-tray-<pid>-<n>/` (`IconName`). Plasma doesn't fall back
  to `IconPixmap`, so with the sandbox's private `/run/user/$UID` the item worked but
  showed no icon (seen in testing). The wrapper runs the indicator with
  `XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR/app/$FLATPAK_ID`, the host-visible directory, after
  making `WAYLAND_DISPLAY` absolute and pinning `PIPEWIRE_RUNTIME_DIR`. Check with
  `busctl --user get-property <item> /StatusNotifierItem org.kde.StatusNotifierItem IconName`:
  the path must be readable on the host.
- `AT_SPI_BUS_ADDRESS` is unset, so AT-SPI asks `org.a11y.Bus` for the host's
  accessibility bus (mounted via `xdg-run/at-spi`). Flatpak's a11y proxy only lets an
  app publish its own tree, and upstream reads other apps' focused text fields.

`sync-assets`: the daemon symlinks `~/.config/wireplumber/{wireplumber.conf.d,scripts}/superwhisper*`
to its WirePlumber assets so the **host's** WirePlumber loads them. keep-inputs-ready keeps
the mic warm so the first word isn't clipped. Pointing into `/app/extra` left a dangling
link on the host (seen in testing). The daemon prefers
`$XDG_DATA_HOME/superwhisper/app/current/assets/wireplumber`, the upstream installer's
layout, so the launcher keeps a copy there, marked `.superwhisper-flatpak`. That path
resolves on both sides. An `app/current` without our marker belongs to upstream's
installer and is left alone.

## fcitx5 text commit

The addon is a library loaded by the **host's** fcitx5. It listens on
`$XDG_RUNTIME_DIR/superwhisper-fcitx5.sock`, and the daemon connects and sends the text
(`VERSION\n` returns the addon version). Three pieces make that cross the sandbox:

1. `ensure-fcitx5` (the launcher runs it at daemon start) writes
   `~/.local/share/fcitx5/addon/superwhisper.conf` when the host has `fcitx5`, as
   upstream's install.sh does. It writes through `flatpak-spawn --host`, so no mount is
   needed and nothing is created for users without fcitx5. `Library=` is
   `<installation>/app/<id>/<arch>/<branch>/active/files/extra/app/lib/fcitx5/libsuperwhisper-fcitx5`,
   derived from `app-path` in `/.flatpak-info`: a host path that flatpak re-points at each
   update. Don't run the daemon *from* that path to get it for free: a daemon started
   before an update would load the new version's files.
2. `--filesystem=xdg-run/superwhisper-fcitx5.sock` shares the socket file. flatpak binds
   it only if it exists when the sandbox starts, and keeps the old inode when fcitx5
   re-creates it.
3. So `superwhisper-flatpak-fcitx5.path` (`PathChanged=%t/superwhisper-fcitx5.sock`)
   starts a oneshot that runs `try-restart` on the daemon. Tested with a stand-in
   listener: socket created after the daemon → one restart, and the daemon's sandbox gets
   `3`. Socket re-created (new inode) → one restart, and the daemon reaches the new one.
   Doctor: `text commit: fcitx5 addon 3`. Not yet tested with a real fcitx5.

`ensure-service` installs all three units and starts the `.path` unit on first install.

## Build

- `build.sh` runs `scripts/build-flatpak.sh` in a Debian 13 container (docker or podman),
  which provides flatpak-builder, minisign and appstreamcli.
- flatpak-builder runs on the **host's architecture**. bubblewrap can't create its
  namespaces under QEMU user emulation, so CI uses a native runner per arch.
- AppStream is composed with Debian's `appstreamcli` after the build
  (`"appstream-compose": false`). On GNOME 49+ runtimes, the in-sandbox compose loads
  icons through glycin, which needs a Flatpak portal that a container doesn't have.
- `gtk4-layer-shell`: the recording indicator `LD_PRELOAD`s `libgtk4-layer-shell.so.0`.
  `wl-clipboard`: the daemon copies results with `wl-copy`. Everything else (python3 +
  PyGObject/pycairo, GTK4, pw-record, pactl, ffmpeg, notify-send, Vulkan loader) is in
  `org.gnome.Platform` 51. `superwhisper doctor` inside the sandbox checks all of it.
- `.gitignore`: a `#` mid-line is part of the pattern. Put comments on their own line.

## Not supported in the Flatpak

- **Muffle**: see above.
- **fcitx5's setup offer** ("Better text insertion available"). The daemon detects fcitx5
  through `applications/org.fcitx.Fcitx5.desktop` in the sandbox's data dirs, so it never
  offers. It would also write that file's path into kwinrc's `InputMethod`, and no path
  it can see is valid on the host. Users pick Fcitx 5 in System Settings. Text commit
  itself works; see below.
- **GNOME Shell extension**: a native install puts it in
  `~/.local/share/gnome-shell/extensions`. On GNOME 48+ the GlobalShortcuts portal covers
  shortcuts.
