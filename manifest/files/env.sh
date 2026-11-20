# Sourced by /app/bin/superwhisper.
# The environment upstream's run.sh expects on a native install. See AGENTS.md.

APP_ID="${FLATPAK_ID:-com.superwhisper.Superwhisper}"
APPDIR=/app/extra/app

# Updates come from the Flatpak repo; upstream's updater would write into /app/extra.
export SUPERWHISPER_UPDATE_DISABLED=1

# The daemon runs as a host systemd user unit (see ensure-service). Upstream asks
# systemctl about $SW_SERVICE_UNIT for start/stop and "launch at login".
export SW_SERVICE_UNIT=superwhisper-flatpak.service

# Settings, history and models live where a native install keeps them (~/.config,
# ~/.local/share, ~/.local/state under superwhisper/, mounted by finish-args), so the
# RPM / upstream installer and this Flatpak share one setup. Caches stay in the
# sandbox's own XDG_CACHE_HOME.
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"

# Every `flatpak run` gets a private /run/user/$UID; $XDG_RUNTIME_DIR/app/$APP_ID is the
# one directory all instances (daemon, settings window, CLI) share, and it is bind
# mounted at the same path on the host, which KWin needs to read the focus script.
export SUPERWHISPER_RUNTIME="$XDG_RUNTIME_DIR/app/$APP_ID/superwhisper"

# The tray icon is a file path the host shell must read; see libexec/…/indicator.
export SW_INDICATOR_BIN=/app/libexec/superwhisper-flatpak/indicator

# Flatpak's accessibility proxy only lets the app publish its own tree. Upstream reads
# the focused text field of other apps, so use the host's AT-SPI bus
# (--filesystem=xdg-run/at-spi): without this variable AT-SPI asks org.a11y.Bus.
unset AT_SPI_BUS_ADDRESS

# libatspi in at-spi2-core 2.62.0–2.62.1 (GNOME 51) segfaults when a host app's direct
# AT-SPI socket, which the sandbox can't reach, fails before the app's root is known.
# It killed desktop_portal.py at login. Preload a shim on those versions only; a runtime
# with the fix (upstream commit 22c0d877) gets none. See atspi-nullroot.c and AGENTS.md.
atspi_version=$(grep -o -m1 'at-spi2-core/[0-9.]*/at-spi2-core-[0-9.]*\.tar' /usr/manifest.json 2>/dev/null) || true
atspi_version=${atspi_version##*/at-spi2-core-}
atspi_shim=/app/libexec/superwhisper-flatpak/libatspi-nullroot.so
case "${atspi_version%.tar}" in
  2.62.0|2.62.0.1|2.62.1)
    case ":${LD_PRELOAD:-}:" in
      *":$atspi_shim:"*) ;;
      *) export LD_PRELOAD="$atspi_shim${LD_PRELOAD:+:$LD_PRELOAD}" ;;
    esac ;;
esac
unset atspi_version atspi_shim
