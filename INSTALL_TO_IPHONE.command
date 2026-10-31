#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/setup

phone_id=$(/usr/bin/python3 - <<'PY'
import json, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix='pocketdesk-') as folder:
    output = pathlib.Path(folder) / 'devices.json'
    subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(output)],
                   check=True, stdout=subprocess.DEVNULL)
    devices = json.loads(output.read_text()).get('result', {}).get('devices', [])
    phones = [d for d in devices
              if d.get('hardwareProperties', {}).get('reality') == 'physical'
              and d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'
              and d.get('connectionProperties', {}).get('pairingState') == 'paired'
              # An idle tunnel reads 'disconnected'; xcodebuild and devicectl reopen it on demand.
              and d.get('connectionProperties', {}).get('tunnelState') != 'unavailable']
    if len(phones) != 1:
        raise SystemExit('설치할 아이폰 1대를 연결하고 잠금을 해제해 주세요.')
    print(phones[0]['hardwareProperties']['udid'])
PY
)

print '연결된 아이폰용으로 빌드하고 서명을 갱신합니다…'
if ! xcodebuild -project PocketDesk.xcodeproj -scheme PocketDesk \
  -configuration Release -sdk iphoneos -destination "id=$phone_id" \
  -destination-timeout 30 -derivedDataPath build/signed-device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  > build/setup/signed-device-build.log 2>&1; then
  tail -70 build/setup/signed-device-build.log
  print '개발자 모드, 아이폰 잠금 해제, Xcode의 Apple 계정과 Team 설정을 확인해 주세요.'
  exit 1
fi

xcrun devicectl device install app --device "$phone_id" \
  build/signed-device/Build/Products/Release-iphoneos/PocketDesk.app \
  --json-output build/setup/device-install.json
bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" build/signed-device/Build/Products/Release-iphoneos/PocketDesk.app/Info.plist)
if ! xcrun devicectl device process launch --device "$phone_id" \
  --terminate-existing "$bundle_id" \
  --json-output build/setup/device-launch.json \
  > build/setup/device-launch.log 2>&1; then
  cat build/setup/device-launch.log
  print '앱 설치는 완료됐지만 실행하지 못했습니다.'
  print '아이폰 잠금을 해제하고, 설정 > 일반 > VPN 및 기기 관리에서 본인의 개발자 계정을 신뢰해 주세요.'
  exit 1
fi
cat build/setup/device-launch.log
print 'PocketDesk 설치·실행 완료.'
