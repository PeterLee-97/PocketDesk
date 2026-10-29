#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/setup
sim_id=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; ds=[d for v in json.load(sys.stdin)["devices"].values() for d in v if d["name"]=="PocketDesk iPhone 16 Pro"]; print(ds[0]["udid"] if ds else "")')
if [[ -z "$sim_id" ]]; then
  print '전용 시뮬레이터가 없습니다. RUN_POCKETDESK.command를 먼저 실행하세요.'
  exit 1
fi
xcodebuild -project PocketDesk.xcodeproj -scheme PocketDesk -configuration Debug \
  -destination "platform=iOS Simulator,id=$sim_id" -derivedDataPath build/simulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO test \
  > build/setup/regression-tests.log 2>&1
python3 Tests/verify_vnc.py
print 'PocketDesk 회귀 검사와 RFB 통합 검사 통과. 로그: build/setup/regression-tests.log'
