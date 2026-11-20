#!/usr/bin/env bash
#
# build-flatpak.sh — runs INSIDE the build container (see build.sh), as the container's
# default user (root). Mounts: /src = this repo (read-only), /work = output + build state,
# /cache = upstream archive cache, /root/.local/share/flatpak = runtime/SDK cache.
#
#   1. resolve Superwhisper's stable release for FLATPAK_ARCH and verify it (size,
#      sha256, minisign signature against the pinned key)
#   2. stage the manifest with the release's URL/sha256/size as extra-data, plus the app
#      icon taken from the verified archive
#   3. flatpak-builder, compose AppStream, export, bundle
#
# Env: FLATPAK_ARCH (required), SW_CHANNEL_FILE (optional saved stable.json), PROJECT_URL.
#
set -euo pipefail
cd /work

set -a; . /src/build.env; set +a
: "${FLATPAK_ARCH:?FLATPAK_ARCH must be set}"
: "${PROJECT_URL:=https://github.com/vintoware/superwhisper-flatpak}"

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# flatpak's per-user installation (its --user flag, not OS privileges) under root's home,
# host-mounted so the runtime and SDK are downloaded once. flatpak refuses a user
# installation as root unless root owns it; with rootless podman this is a no-op.
export XDG_RUNTIME_DIR=/tmp/runtime-root
export FLATPAK_USER_DATA=/root/.local/share/flatpak
mkdir -p "$FLATPAK_USER_DATA" "$XDG_RUNTIME_DIR"
chown -R 0:0 "$FLATPAK_USER_DATA"
chmod 700 "$XDG_RUNTIME_DIR"
echo "flatpak $(flatpak --version | cut -d' ' -f2), flatpak-builder $(flatpak-builder --version | cut -d' ' -f2)"
echo "arch=$FLATPAK_ARCH app=$APP_ID branch=$FLATPAK_BRANCH runtime=$FLATPAK_RUNTIME/$FLATPAK_RUNTIME_VERSION"

log "Resolving and verifying Superwhisper ($FLATPAK_ARCH)"
python3 -I /src/scripts/upstream.py fetch \
  --arch "$FLATPAK_ARCH" \
  --key /src/manifest/superwhisper-release.pub \
  --cache /cache \
  --out /work/upstream.env \
  ${SW_CHANNEL_FILE:+--channel-file "$SW_CHANNEL_FILE"}
# shellcheck disable=SC1091
. /work/upstream.env
VERSION="$SW_VERSION-$PKG_REVISION"
export SW_URL SW_SHA256 SW_SIZE SW_VERSION SW_DATE SW_NOTES_URL PROJECT_URL

log "Staging manifest (Superwhisper $SW_VERSION, package $VERSION)"
rm -rf stage
mkdir -p stage/icons
cp -a /src/manifest/files stage/files
cp /src/manifest/"$APP_ID".json stage/manifest.json
tar --zstd -xf "$SW_ARCHIVE" -C stage/icons --strip-components=4 --wildcards '*/app/assets/app-icon/*.png'
ls stage/icons
python3 -I - stage/manifest.json "stage/files/$APP_ID.metainfo.xml" <<'PY'
import os, re, sys
values = {
    "APP_ID": os.environ["APP_ID"], "BRANCH": os.environ["FLATPAK_BRANCH"],
    "RUNTIME": os.environ["FLATPAK_RUNTIME"], "SDK": os.environ["FLATPAK_SDK"],
    "RUNTIME_VERSION": os.environ["FLATPAK_RUNTIME_VERSION"],
    "SW_URL": os.environ["SW_URL"], "SW_SHA256": os.environ["SW_SHA256"],
    "SW_SIZE": os.environ["SW_SIZE"], "SW_VERSION": os.environ["SW_VERSION"],
    "SW_DATE": os.environ["SW_DATE"], "SW_NOTES_URL": os.environ["SW_NOTES_URL"],
    "PROJECT_URL": os.environ["PROJECT_URL"],
}
for path in sys.argv[1:]:
    text = open(path).read()
    for key, value in values.items():
        text = text.replace(f"@{key}@", value)
    left = re.findall(r"@[A-Z_]+@", text)
    if left:
        sys.exit(f"{path}: unrendered placeholders {sorted(set(left))}")
    open(path, "w").write(text)
PY

log "Installing $FLATPAK_SDK and $FLATPAK_RUNTIME $FLATPAK_RUNTIME_VERSION ($FLATPAK_ARCH)"
# Full refs: flatpak-builder won't pull the base itself, and id:branch is rejected.
flatpak remote-add --if-not-exists --user flathub "$FLATPAK_REMOTE_URL"
flatpak install --user -y --noninteractive flathub \
  "$FLATPAK_SDK/$FLATPAK_ARCH/$FLATPAK_RUNTIME_VERSION" \
  "$FLATPAK_RUNTIME/$FLATPAK_ARCH/$FLATPAK_RUNTIME_VERSION"

log "flatpak-builder"
flatpak-builder --force-clean --user --arch="$FLATPAK_ARCH" build-dir stage/manifest.json

# AppStream is composed here, not by flatpak-builder ("appstream-compose": false): on
# GNOME 49+ runtimes its in-sandbox compose loads icons through glycin, which needs the
# Flatpak portal on a session bus that a container doesn't have.
log "AppStream"
appstreamcli compose --no-net --prefix=/ \
  --origin="$APP_ID" \
  --result-root=build-dir/files \
  --data-dir=build-dir/files/share/app-info/xmls \
  --icons-dir=build-dir/files/share/app-info/icons/flatpak \
  --components="$APP_ID" \
  build-dir/files
[ -s "build-dir/files/share/app-info/xmls/$APP_ID.xml.gz" ] || { echo "appstream compose produced no catalog" >&2; exit 1; }

log "Export and bundle"
grep -A4 'Extra Data' build-dir/metadata
rm -rf repo
flatpak build-export --arch="$FLATPAK_ARCH" repo build-dir "$FLATPAK_BRANCH"
mkdir -p dist
BUNDLE="dist/$APP_ID.$FLATPAK_ARCH.flatpak"
flatpak build-bundle --arch="$FLATPAK_ARCH" --runtime-repo="$FLATPAK_REMOTE_URL" \
  repo "$BUNDLE" "$APP_ID" "$FLATPAK_BRANCH"

# Leak guard: the bundle must not carry upstream's binaries (only the icon PNGs).
if ostree ls -R --repo=repo "app/$APP_ID/$FLATPAK_ARCH/$FLATPAK_BRANCH" /files \
     | grep -E '/(extra/|lib/libonnxruntime|bin/(asr-worker|cleanup-worker|superwhisper-settings|superwhisper-indicator)$)'; then
  echo "bundle contains upstream binaries (see above)" >&2; exit 1
fi

jq_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
cat > "dist/build-inputs.$FLATPAK_ARCH.json" <<EOF
{
  "app_id": $(jq_escape "$APP_ID"),
  "arch": $(jq_escape "$FLATPAK_ARCH"),
  "branch": $(jq_escape "$FLATPAK_BRANCH"),
  "version": $(jq_escape "$VERSION"),
  "superwhisper_version": $(jq_escape "$SW_VERSION"),
  "superwhisper_url": $(jq_escape "$SW_URL"),
  "superwhisper_sha256": $(jq_escape "$SW_SHA256"),
  "superwhisper_size": $SW_SIZE,
  "runtime": $(jq_escape "$FLATPAK_RUNTIME/$FLATPAK_ARCH/$FLATPAK_RUNTIME_VERSION"),
  "bundle_sha256": $(jq_escape "$(sha256sum "$BUNDLE" | cut -d' ' -f1)")
}
EOF
cat "dist/build-inputs.$FLATPAK_ARCH.json"
echo
echo "BUNDLE OK: /work/$BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
