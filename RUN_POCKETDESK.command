#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/setup

simulator_id=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
matches = [d for d in devices if d["name"] == "PocketDesk iPhone 16 Pro"]
print(matches[0]["udid"] if matches else "")
')

if [[ -z "$simulator_id" ]]; then
  runtime_id=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
runtimes.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")), reverse=True)
print(runtimes[0]["identifier"] if runtimes else "")
')
  if [[ -z "$runtime_id" ]]; then
    print 'iOS 시뮬레이터가 없습니다. Xcode > Settings > Components에서 iOS를 설치해 주세요.'
    read '?Enter를 누르면 종료합니다. '
    exit 1
  fi
  simulator_id=$(xcrun simctl create 'PocketDesk iPhone 16 Pro' \
    com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$runtime_id")
fi

print 'PocketDesk를 빌드하고 실행합니다…'
xcrun simctl bootstatus "$simulator_id" -b
developer_dir=$(xcode-select -p)
device_hub="${developer_dir%/Contents/Developer}/Contents/Applications/DeviceHub.app"
if [[ -d "$device_hub" ]]; then
  open "$device_hub"
else
  open -a Simulator --args -CurrentDeviceUDID "$simulator_id"
fi
if ! xcodebuild -project PocketDesk.xcodeproj -scheme PocketDesk \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build \
  > build/setup/simulator-build.log 2>&1; then
  tail -80 build/setup/simulator-build.log
  read '?빌드 실패. Enter를 누르면 종료합니다. '
  exit 1
fi
xcrun simctl install "$simulator_id" build/simulator/Build/Products/Debug-iphonesimulator/PocketDesk.app
bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" build/simulator/Build/Products/Debug-iphonesimulator/PocketDesk.app/Info.plist)
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"
print '실행 완료. Device Hub에서 PocketDesk iPhone 16 Pro를 선택해 주세요.'
