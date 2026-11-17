#!/bin/sh
# Writes appcast.xml: the file Sheaf's updater (Sparkle) reads to find out about
# a new build. It describes one build: its version, release notes, and where to
# download the zip, with an EdDSA signature that Sheaf checks before installing.
#
# Usage: Scripts/make-appcast.sh <Sheaf.app> <Sheaf.zip> <download URL> <notes> <sign_update>
#
# The signing key comes from the SPARKLE_PRIVATE_KEY environment variable (on
# GitHub), or else from the keychain account "sheaf" (on the developer's Mac).
set -eu

app=$1 zip=$2 url=$3 notes=$4 sign_update=$5

plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
minimum_macos=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")

# Prints: sparkle:edSignature="…" length="…"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$zip")
else
  signature=$("$sign_update" --account sheaf "$zip")
fi
case $signature in
  *edSignature=*length=*) ;;
  *) echo "make-appcast: signing failed: $signature" >&2; exit 1 ;;
esac

# The notes go inside CDATA, which ends at the first "]]>": split any in the text.
notes=$(printf '%s' "$notes" | sed 's/]]>/]]]]><![CDATA[>/g')
date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sheaf</title>
    <item>
      <title>Sheaf $version (build $build)</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_macos</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[$notes]]></description>
      <enclosure url="$url" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
