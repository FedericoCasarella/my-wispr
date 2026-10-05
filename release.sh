#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
release_stage=$(mktemp -d /tmp/my-wispr-dmg.XXXXXX)
trap 'rm -rf "$release_stage"' EXIT
ditto build/MyWispr.app "$release_stage/MyWispr.app"
ln -s /Applications "$release_stage/Applications"
cat > "$release_stage/Installazione.txt" <<'TXT'
My Wispr — Mac Apple Silicon, macOS 26 o successivo

Trascina MyWispr.app in Applications, poi aprila dalla cartella Applicazioni.
Questa anteprima non è notarizzata da Apple. Se macOS blocca l’apertura, vai in
Impostazioni di Sistema → Privacy e sicurezza e usa Apri comunque solo se ti fidi della provenienza.
Autorizza Microfono e Accessibilità quando richiesto dall’app.
TXT
hdiutil create -volname 'My Wispr' -srcfolder "$release_stage" -ov -format UDZO "build/My-Wispr-${version}-arm64.dmg"
hdiutil verify "build/My-Wispr-${version}-arm64.dmg"
(cd build && shasum -a 256 "My-Wispr-${version}-arm64.dmg" > "My-Wispr-${version}-arm64.dmg.sha256")
