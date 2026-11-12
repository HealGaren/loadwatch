#!/bin/zsh
# LoadWatch 빌드·설치: ~/Applications/LoadWatch.app + 로그인 시 자동 실행 + ~/.local/bin/loadwatch
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/LoadWatch.app"
LABEL="com.garen.loadwatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p build
swiftc -O -o build/LoadWatch Sources/main.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/LoadWatch "$APP/Contents/MacOS/LoadWatch"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>LoadWatch</string>
  <key>CFBundleExecutable</key><string>LoadWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

# 메뉴바 클릭이 굼뜨지 않게 앱은 보통 우선순위로 띄운다. 측정만 앱 안에서 utility 큐(낮은 우선순위)로 돈다.
# 메뉴에서 종료하면(정상 종료) 다시 띄우지 않고, 죽었을 때만 다시 띄운다.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/LoadWatch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/LoadWatch/stderr.log</string>
</dict>
</plist>
EOF
mkdir -p "$HOME/Library/Logs/LoadWatch" "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/LoadWatch" "$HOME/.local/bin/loadwatch"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout 은 비동기라 내려갈 때까지 기다려야 bootstrap 이 실패하지 않는다
for _ in {1..50}; do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.2; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "설치 완료: $APP"
