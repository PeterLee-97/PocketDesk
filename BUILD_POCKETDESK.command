#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/setup
print '아이폰용 Release를 컴파일합니다. 기기 설치는 실행하지 않습니다.'
if ! xcodebuild -project PocketDesk.xcodeproj -scheme PocketDesk \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/release CODE_SIGNING_ALLOWED=NO build \
  > build/setup/release-build.log 2>&1; then
  tail -70 build/setup/release-build.log
  exit 1
fi
print 'Release 컴파일 완료: build/release/Build/Products/Release-iphoneos/PocketDesk.app'
print '기기 설치에는 개발 서명이 필요합니다. 설치할 때 INSTALL_TO_IPHONE.command를 실행하세요.'
