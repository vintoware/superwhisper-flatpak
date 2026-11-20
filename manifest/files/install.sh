#!/bin/sh
#
# install.sh — runs inside the flatpak-builder sandbox (cwd = this module's sources).
# Installs only our own files into /app. Superwhisper itself is extra-data: flatpak
# downloads upstream's release archive on the user's machine and apply_extra unpacks it
# into /app/extra (see AGENTS.md). The one upstream asset in the bundle is the app icon,
# copied from the verified archive by the build so launchers can show it.
#
set -eu
: "${APP_ID:?}"
SHARE=/app/share/superwhisper-flatpak
LIBEXEC=/app/libexec/superwhisper-flatpak

install -Dm755 apply_extra /app/bin/apply_extra
install -Dm755 superwhisper /app/bin/superwhisper
install -Dm755 ensure-service "$LIBEXEC/ensure-service"
install -Dm755 sync-assets "$LIBEXEC/sync-assets"
install -Dm644 env.sh "$LIBEXEC/env.sh"
install -Dm644 uninstall.sh "$SHARE/uninstall.sh"
sed "s|@APP_ID@|$APP_ID|g" superwhisper-flatpak.service > service
install -Dm644 service "$SHARE/superwhisper-flatpak.service"

# Host commands. Superwhisper drives systemd user units, KWin/KDE config, Hyprland and
# the lock-screen check through these; each one runs the real command on the host.
install -Dm755 host-command "$LIBEXEC/host-command"
for cmd in systemctl busctl kreadconfig5 kreadconfig6 kwriteconfig6 hyprctl gsettings \
           wtype ydotool pgrep wireplumber fc-cache; do
  ln -s "$LIBEXEC/host-command" "/app/bin/$cmd"
done
# Upstream only uses systemd-run for Muffle, which can't work from a Flatpak (see the shim).
install -Dm755 systemd-run /app/bin/systemd-run

install -Dm644 "$APP_ID.desktop" "/app/share/applications/$APP_ID.desktop"
install -Dm644 "$APP_ID.UrlHandler.desktop" "/app/share/applications/$APP_ID.UrlHandler.desktop"
install -Dm644 "$APP_ID.metainfo.xml" "/app/share/metainfo/$APP_ID.metainfo.xml"

found=0
for png in icons/*.png; do
  size=$(basename "$png" .png)
  case "$size" in 16|32|64|128|256|512) ;; *) continue ;; esac
  install -Dm644 "$png" "/app/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "install.sh: no icons staged" >&2; exit 1; }

echo "installed $APP_ID wrapper; Superwhisper itself arrives as extra-data"
