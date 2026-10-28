#!/usr/bin/env bash
# Writes appcast.xml: the feed the app's updater reads to find a new version. It lists one
# version, the zipped app with its EdDSA signature, so a download that was changed on the way is
# refused.
#
#   scripts/make-appcast.sh VERSION ZIP OUT [NOTES]
#
#   VERSION                 the version in the zipped app, such as 1.2.0
#   ZIP                     the zipped Moire.app
#   OUT                     where to write the feed
#   NOTES                   optional file with one change per line, shown in the update window
#   SPARKLE_ED_PRIVATE_KEY  the private signing key; without it, the key in the Keychain under the
#                           account "moire" is used
#   DOWNLOAD_URL            where the app downloads the zip (default: this version's GitHub release)
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 VERSION ZIP OUT [NOTES]" >&2
    exit 2
fi
version="$1"
zip="$2"
out="$3"
notes="${4:-}"
repo="https://github.com/SherinBloemendaal/moire"
url="${DOWNLOAD_URL:-$repo/releases/download/v$version/Moire.zip}"

cd "$(dirname "$0")/.."
sign_update=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$sign_update" ]; then
    swift package resolve >/dev/null
fi

if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT
    chmod 600 "$key_file"
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$key_file"
    attributes="$("$sign_update" --ed-key-file "$key_file" "$zip")"
else
    attributes="$("$sign_update" --account moire "$zip")"
fi
case "$attributes" in
    *sparkle:edSignature=*length=*) ;;
    *) echo "sign_update gave no signature: $attributes" >&2; exit 1 ;;
esac

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

description=""
if [ -n "$notes" ] && [ -s "$notes" ]; then
    description="<ul>"
    while IFS= read -r line; do
        [ -n "$line" ] && description+="<li>$(printf '%s' "$line" | escape)</li>"
    done < "$notes"
    description+="</ul>"
fi

cat > "$out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Moire</title>
    <link>$repo</link>
    <item>
      <title>Moire $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repo/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$description]]></description>
      <enclosure url="$url" type="application/octet-stream" $attributes />
    </item>
  </channel>
</rss>
EOF
echo "Wrote $out"
