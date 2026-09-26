#!/bin/bash
#
#  Nexiitt Recorder — one-click installer (macOS)
#  ------------------------------------------------
#  Yeh script khud ye sab karti hai:
#    1. Aapke Mac ka CPU dekh kar sahi build choose karti hai
#    2. v1.5.3 download karti hai
#    3. SHA256 checksum verify karti hai (asli hai ya nahi)
#    4. Purana NexIIT Recorder Trash me bhej deti hai
#    5. Naya app /Applications me install karti hai
#    6. macOS ka "malware" block hatati hai
#
#  Aapko sirf is file par double-click karna hai.
#
set -euo pipefail

# ----------------------------------------------------------------------------
#  Settings
# ----------------------------------------------------------------------------
REPO="saurabhkumar805274-jpg/nexiit-recorder"
VERSION="v1.5.3"
BASE="https://github.com/$REPO/releases/download/$VERSION"
APP_NAME="Nexiitt Recorder"
OLD_APP_NAME="NexIIT Recorder"
EXPECT_BUNDLE_ID="app.nexiitt.recorder"

# Checksums release build ke waqt pin kiye gaye hain.
# Script download ke baad inhi se compare karti hai — agar koi file badli hui
# toh script install karne se PEHLE ruk jayegi. Isiliye checksum step sabse
# zaroori hai (hum quarantine hata rahe hain).
SHA_ARM64="0a81737494f5d318ca814eab37af459230565b00d92e2eaa0e4e85ae22d2cdae"
SHA_X64="f16600ff8ab5d4b27c19e229303cc79d626a9c1ea5e297052838fa9a8adadd85"

INSTALL_DIR="${NEXIITT_INSTALL_DIR:-/Applications}"
LOCAL_ZIP="${NEXIITT_LOCAL_ZIP:-}"   # test ke liye
BUNDLE_ID_OVERRIDE="${NEXIITT_BUNDLE_ID:-$EXPECT_BUNDLE_ID}"

# ----------------------------------------------------------------------------
#  Helpers
# ----------------------------------------------------------------------------
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '  \033[36m->\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31m%s\033[0m\n\n' "$*"; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Script pe khud agar quarantine laga ho toh hata do
xattr -d com.apple.quarantine "$0" 2>/dev/null || true
xattr -d com.google.Chrome "$0"       2>/dev/null || true

# ----------------------------------------------------------------------------
#  0. Sanity
# ----------------------------------------------------------------------------
say "Nexiitt Recorder $VERSION — Installer"

if [ "$(uname -s)" != "Darwin" ]; then
  die "Yeh script sirf macOS ke liye hai."
fi

# ----------------------------------------------------------------------------
#  1. CPU detect
# ----------------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ASSET="Nexiitt-Recorder-mac-arm64.zip"; EXPECT="$SHA_ARM64"; CPULABEL="Apple Silicon" ;;
  x86_64) ASSET="Nexiitt-Recorder-mac-x64.zip";   EXPECT="$SHA_X64";   CPULABEL="Intel" ;;
  *) die "Samajh nahi aaya aapka CPU: $ARCH. Please report karo." ;;
esac
step "Aapka Mac: $CPULABEL ($ARCH)"

# ----------------------------------------------------------------------------
#  2. Download (with resume — network aksar beech me toot-ta hai)
# ----------------------------------------------------------------------------
ZIP="$WORK/app.zip"
if [ -n "$LOCAL_ZIP" ]; then
  cp "$LOCAL_ZIP" "$ZIP"
  ok "Local build use ho rahi hai (test mode)"
else
  say "2/6  Download  (ye 1-2 minute le sakta hai)"
  touch "$ZIP"
  ATTEMPT=0
  until unzip -tq "$ZIP" >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -gt 6 ] && die "Download baar baar fail ho raha hai. Internet check karke dobara chalayein."
    step "try $ATTEMPT/6 ..."
    curl -fsSL --retry 3 --retry-all-errors --connect-timeout 30 -C - \
         -o "$ZIP" "$BASE/$ASSET" || true
    sleep 2
  done
  ok "$(du -h "$ZIP" | cut -f1) download hua"
fi

# ----------------------------------------------------------------------------
#  3. Checksum verify  (SABSE ZAROORI — quarantine hatane se pehle)
# ----------------------------------------------------------------------------
say "3/6  Verify"
ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECT" ]; then
  bad "Checksum mismatch!"
  printf '     expected: %s\n     actual  : %s\n' "$EXPECT" "$ACTUAL"
  die "File asli nahi lagti. Install nahi kiya ja raha. (Isse bachne ke liye checksum step zaroori tha.)"
fi
ok "Checksum match — file asli hai"

# ----------------------------------------------------------------------------
#  4. Extract
# ----------------------------------------------------------------------------
say "4/6  Extract"
ditto -x -k "$ZIP" "$WORK/x" 2>/dev/null
NEW_APP="$WORK/x/$APP_NAME.app"
[ -d "$NEW_APP" ] || die "App bundle extract nahi hua."

# Ek extra safety check — galat app install na ho
REAL_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$NEW_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")"
if [ "$BUNDLE_ID_OVERRIDE" != "*" ] && [ "$REAL_ID" != "$BUNDLE_ID_OVERRIDE" ]; then
  die "Bundle ID expected '$BUNDLE_ID_OVERRIDE' tha, par mila '$REAL_ID'. Install nahi kiya."
fi
ok "App identity verify: $REAL_ID"

# ----------------------------------------------------------------------------
#  5. Purana app hatao (Trash me — undo ho sakta hai)
# ----------------------------------------------------------------------------
say "5/6  Purana app hatana"
MOVED_OLD=""
for OLD in "$INSTALL_DIR/$OLD_APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"; do
  if [ -e "$OLD" ]; then
    pkill -x "$(basename "$OLD" .app)" 2>/dev/null || true
    TRASH="$HOME/.Trash/$(basename "$OLD").$(date +%H%M%S)"
    if mv "$OLD" "$TRASH" 2>/dev/null; then
      MOVED_OLD="$TRASH"
      ok "$(basename "$OLD") -> Trash  (undo: Trash se wapas khinchein)"
    else
      bad "$(basename "$OLD") hat nahi paya — aap manually hata lein"
    fi
  fi
done
[ -n "$MOVED_OLD" ] || ok "Purana app nahi tha"

# ----------------------------------------------------------------------------
#  6. Install
# ----------------------------------------------------------------------------
say "6/6  Install"
if ! cp -R "$NEW_APP" "$INSTALL_DIR/"; then
  die "Copy nahi hua. /Applications likhne ke liye sudo chahiye — manually chalayein:
     sudo ditto \"$NEW_APP\" \"$INSTALL_DIR/\""
fi
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
[ -d "$INSTALLED" ] || die "Install verify nahi hua."

# macOS quarantine + browser flags hatanao
xattr -cr "$INSTALLED" 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
xattr -dr com.google.Chrome "$INSTALLED" 2>/dev/null || true
xattr -dr com.google.Chrome.crashpad "$INSTALLED" 2>/dev/null || true
ok "macOS block hataya"

# ----------------------------------------------------------------------------
say "Ho gaya"
printf '  App   : %s\n' "$INSTALLED"
printf '  Size  : %s\n' "$(du -sh "$INSTALLED" | cut -f1)"
printf '\n  Ab %s kholein (Applications folder se).\n\n' "$APP_NAME"

if [ -n "$MOVED_OLD" ]; then
  printf '  Note: purana app Trash me hai (%s)\n' "$(basename "$MOVED_OLD")"
fi
printf '  Aapki recordings/projects safe hain — woh app ke andar nahi,\n'
printf '  ~/Library/Application Support me hain.\n\n'

read -r -p "  Enter dabayein band karne ke liye..." _
exit 0
