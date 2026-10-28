#!/usr/bin/env bash
# Writes appcast.xml: the feed the app's updater reads to find a new version. It lists one
# version, the zipped app with its EdDSA signature, and the feed is signed too, so a download or
# a feed that was changed on the way is refused.
#
#   scripts/make-appcast.sh VERSION ZIP OUT [NOTES]
#
#   VERSION                 the version in the zipped app, such as 1.2.0
#   ZIP                     the zipped Moire.app
#   OUT                     where to write the feed
#   NOTES                   optional file with one change per line, shown in the update window
#   SPARKLE_ED_PRIVATE_KEY  the private signing key; without it, the key is read from 1Password
#                           (needs `op`)
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

# The key lives only in 1Password; CI gets a copy as the SPARKLE_ED_PRIVATE_KEY secret.
key_item="op://Employee/p6xtbxdvg3un4vxzewckz3c5vm/password"
if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    SPARKLE_ED_PRIVATE_KEY="$(op read "$key_item")"
fi
SPARKLE_ED_PRIVATE_KEY="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | tr -d '\n')"
if ! printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$|^[A-Za-z0-9+/]{86}==$'; then
    echo "SPARKLE_ED_PRIVATE_KEY is not a private key: it should be one line of base64, as generate_keys -x writes it" >&2
    exit 1
fi

# The output of sign_update is never printed: when it fails, it can repeat the key it was given.
sign() {
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$@" 2>/dev/null
}

attributes="$(sign "$zip")" || attributes=""
case "$attributes" in
    *sparkle:edSignature=*length=*) ;;
    *) echo "sign_update could not sign $zip with the private key" >&2; exit 1 ;;
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

# Embeds the feed's own signature in it; the app refuses a feed without one.
if ! sign "$out" >/dev/null || ! grep -q "sparkle-signatures" "$out"; then
    echo "sign_update could not sign $out with the private key" >&2
    exit 1
fi
echo "Wrote $out"
