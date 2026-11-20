#!/bin/bash
# Builds build/Mtfy.app. Pass --install to copy it to ~/Applications, launch it, and install
# the `mtfy` command in ~/.local/bin.
# Signs with your Apple Development identity if present (override with SIGN_IDENTITY), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Mtfy.app
ICON=build/AppIcon.icns

swift build -c release

# Rebuilt when the icon script or the logo changes.
if [[ ! -f $ICON || scripts/make-icon.swift -nt $ICON || Resources/MenuBarIcon.svg -nt $ICON ]]; then
    mkdir -p build
    tmp=$(mktemp -d)
    swift scripts/make-icon.swift Resources/MenuBarIcon.svg "$tmp/icon.png"
    mkdir "$tmp/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$tmp/AppIcon.iconset" -o "$ICON"
    rm -rf "$tmp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Mtfy" "$APP/Contents/MacOS/Mtfy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.svg "$APP/Contents/Resources/MenuBarIcon.svg"

# A stable identity keeps Keychain access across rebuilds; ad-hoc signing changes every build.
if [[ -z ${SIGN_IDENTITY:-} ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}
echo "Signing with: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ ${1:-} == --install ]]; then
    DEST="$HOME/Applications/Mtfy.app"
    pkill -x Mtfy 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    # Keep only the installed copy, so Spotlight and Launchpad don't list two Mtfy apps.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
    rm -rf "$APP"
    open "$DEST"
    echo "Installed and launched $DEST"

    # The `mtfy` command: a wrapper rather than a symlink, so the program runs from inside the
    # app and finds its settings. Never replaces an `mtfy` this script didn't write.
    BIN="$HOME/.local/bin/mtfy"
    MARK="# Installed by mtfy build.sh"
    if [[ -e $BIN ]] && ! grep -qF "$MARK" "$BIN"; then
        echo "Not installing the mtfy command: $BIN already exists"
    else
        mkdir -p "$(dirname "$BIN")"
        printf '#!/bin/sh\n%s\nexec "%s/Contents/MacOS/Mtfy" "$@"\n' "$MARK" "$DEST" > "$BIN"
        chmod +x "$BIN"
        echo "Installed the mtfy command at $BIN"
        [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "Add ~/.local/bin to your PATH to use it"
    fi
fi
