#!/bin/sh
# Replaces upstream's app/uninstall.sh in the Flatpak (apply_extra copies it in).
echo "Superwhisper was installed as a Flatpak. Remove it with:" >&2
echo "  systemctl --user disable --now superwhisper-flatpak.service superwhisper-flatpak-fcitx5.path" >&2
echo "  rm ~/.config/systemd/user/superwhisper-flatpak*  ~/.local/share/fcitx5/addon/superwhisper.conf" >&2
echo "  flatpak uninstall com.superwhisper.Superwhisper" >&2
echo "Your settings, history and models under ~/.config, ~/.local/share and ~/.local/state (superwhisper/) are kept." >&2
exit 1
