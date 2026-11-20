# Superwhisper for Linux — Flatpak repo

[Superwhisper](https://superwhisper.com) for Linux (x86_64 and aarch64) as a Flatpak.
GitHub Actions rebuilds it whenever Superwhisper publishes a stable release and publishes
it to the Flatpak repo [vintoware/flatpak-repo](https://github.com/vintoware/flatpak-repo)
(GitHub Pages).

- **No Superwhisper binaries are redistributed.** Superwhisper is proprietary, so the
  Flatpak uses [extra-data](https://docs.flatpak.org/en/latest/module-sources.html#extra-data),
  like Flathub does for Slack or Spotify. When you install or update, flatpak downloads
  Superwhisper's official release archive **from superwhisper.com**, checks its SHA-256
  and size, and unpacks it on your machine (`manifest/files/apply_extra`). The bundle
  holds only this repo's packaging, two open-source libraries, and the app icon.
- **Verified releases.** Before a build uses a release, CI checks the archive against the
  stable channel's size and SHA-256, and checks its minisign signature against
  Superwhisper's pinned Linux release key.
- **Automatic updates.** `.github/workflows/build.yml` checks
  `https://tux.superwhisper.com/stable.json` every 4 hours. A new version is built on native
  x86_64 and arm64 runners and arrives with `flatpak update`.

> Unofficial. Not affiliated with or supported by Superwhisper.

## Install

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --user --if-not-exists vintoware https://vintoware.github.io/flatpak-repo/vintoware.flatpakrepo
flatpak install --user vintoware com.superwhisper.Superwhisper
```

Open **Superwhisper** from the application launcher. The first launch installs and
starts a systemd user service, `superwhisper-flatpak.service`, which runs the dictation
daemon and starts at login. KDE Plasma and GNOME then ask you to confirm the shortcuts
(default: **hold F9** to dictate, **Escape** to cancel). On the first dictation, they ask
to let Superwhisper "control input devices", which is how it sends the paste keystroke.

The CLI works through flatpak:

```sh
flatpak run --command=superwhisper com.superwhisper.Superwhisper status
flatpak run --command=superwhisper com.superwhisper.Superwhisper doctor
journalctl --user -t superwhisper-flatpak -f        # daemon log
```

### Coming from the RPM or upstream's installer

Settings, history and downloaded models are shared with a native install:
`~/.config/superwhisper`, `~/.local/share/superwhisper` and `~/.local/state/superwhisper`.
Switching keeps your setup, and models aren't downloaded again.

Only one daemon can own the shortcuts. While a native `superwhisper.service` is running,
the Flatpak's service doesn't start. Opening the Flatpak then shows a notification
saying so. To switch:

```sh
systemctl --user disable --now superwhisper.service       # or: sudo dnf remove superwhisper
systemctl --user enable --now superwhisper-flatpak.service
```

### Uninstall

```sh
systemctl --user disable --now superwhisper-flatpak.service
rm ~/.config/systemd/user/superwhisper-flatpak.service
flatpak uninstall com.superwhisper.Superwhisper
```

If you skip the first two steps, the leftover unit does nothing: it checks that the
Flatpak is installed before it starts.

## What works

Tested on Fedora Asahi (aarch64), KDE Plasma 6.8, Wayland:

| | |
|---|---|
| Offline transcription (Vulkan) and cleanup, Cloud | ✓ GPU self-check passes in the sandbox |
| Shortcuts (GlobalShortcuts portal), paste (RemoteDesktop portal), clipboard | ✓ |
| Recording indicator (layer shell), Settings window | ✓ |
| Focus tracking (KWin script), lock-screen check, launch at login | ✓ through the host |
| Microphone warm-up (WirePlumber `keep-inputs-ready`) | ✓ |
| Restart on crash, clean stop/restart of the service | ✓ |
| **Muffle** (duck other audio with a filter) | ✗ the daemon lowers other apps' volume instead |
| **fcitx5 text commit** | ✗ text is pasted instead |
| GNOME Shell extension (push to talk on GNOME < 48) | ✗ |

The x86_64 build comes from the same manifest, but only the aarch64 build has been tested
on hardware.

## How it works

```
tux.superwhisper.com/stable.json  ──►  scripts/upstream.py: download the archive for this
                                       arch, check size + sha256 + minisign signature
manifest/ (org.gnome.Platform 51)  ──►  flatpak-builder: gtk4-layer-shell, wl-clipboard,
                                       launcher + host shims + desktop files + icon;
                                       the archive's URL/sha256/size become extra-data
GitHub release v<version>          ──►  apps/com.superwhisper.Superwhisper.<arch>.json pushed
                                       to flatpak-repo, which signs + serves the builds

on your machine, at install/update time (flatpak; no network in the hook):
  download superwhisper-omarchy-<arch>-<ver>.tar.zst from superwhisper.com  ──►  apply_extra:
  unpack to /app/extra, check every file against the archive's MANIFEST.sha256
```

Superwhisper is built around a systemd user service and uses host tools such as
`systemctl`, KWin scripting and WirePlumber. This Flatpak therefore gives the app the
session bus and runs those commands on the host. **It is a packaging format here, not a
security sandbox.** AGENTS.md explains each piece.

## Build locally

Needs docker or podman. The build runs in a Debian container on the host's architecture:

```sh
./build.sh                       # dist/com.superwhisper.Superwhisper.<arch>.flatpak
```

Flatpak can't install an extra-data app from a bundle file ("Extra data missing in
detached metadata"). Install from the build's repo instead:

```sh
flatpak build-update-repo .work/repo
flatpak remote-add --user --no-gpg-verify sw-local "file://$PWD/.work/repo"
flatpak install --user sw-local com.superwhisper.Superwhisper
```

## CI / repo hosting

| Piece | Where |
|---|---|
| Release check | `https://tux.superwhisper.com/stable.json`, every 4 hours |
| Version | `<superwhisper version>-<PKG_REVISION>` (`build.env`); bump `PKG_REVISION` to ship a packaging change |
| "Already published?" | both `apps/com.superwhisper.Superwhisper.<arch>.json` in `vintoware/flatpak-repo` list that version |
| Build runners | `ubuntu-24.04` (x86_64), `ubuntu-24.04-arm` (aarch64), native |
| Artifacts | both bundles on the GitHub release `v<version>` (no Superwhisper binaries inside) |
| Hand-off | pointer files pushed to `flatpak-repo` with the `FLATPAK_REPO_DEPLOY_KEY` secret |
| Hosting/signing | `flatpak-repo`'s workflow imports, signs, builds static deltas, deploys to Pages |
| Manual run | Actions → *Build and publish* → *Run workflow* (optional `force`) |
