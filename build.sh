#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/MyWispr.app/Contents/MacOS build/MyWispr.app/Contents/Resources build/module-cache
swiftc -swift-version 6 -target arm64-apple-macosx26.0 -module-cache-path build/module-cache -O -parse-as-library Sources/*.swift -o build/MyWispr.app/Contents/MacOS/MyWispr
cp Info.plist build/MyWispr.app/Contents/Info.plist
cp Resources/*.wav Resources/*.png build/MyWispr.app/Contents/Resources/
codesign --force --sign - --identifier it.federico.mywispr --requirements '=designated => identifier "it.federico.mywispr";' build/MyWispr.app
print "App pronta: $PWD/build/MyWispr.app"
