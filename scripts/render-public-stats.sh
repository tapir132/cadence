#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 6 ]]; then
  echo "usage: $0 RELEASES_JSON REPOSITORY_JSON [VIEWS_JSON] [CLONES_JSON] [UPDATED_AT] [REPOSITORY]" >&2
  exit 64
fi

RELEASES_JSON="$1"
REPOSITORY_JSON="$2"
VIEWS_JSON="${3:-/dev/null}"
CLONES_JSON="${4:-/dev/null}"
UPDATED_AT="${5:-$(date -u '+%Y-%m-%d %H:%M UTC')}"
REPOSITORY="${6:-tapir132/cadence}"

jq -e 'type == "array"' "$RELEASES_JSON" >/dev/null
jq -e 'type == "object"' "$REPOSITORY_JSON" >/dev/null

release_total() {
  local release_filter="$1"
  local asset_filter="$2"
  jq --arg release_filter "$release_filter" --arg asset_filter "$asset_filter" '
    [
      .[]
      | select(
          if $release_filter == "stable"
          then (.draft == false and .prerelease == false)
          else (.draft == false and .tag_name == "edge")
          end
        )
      | .assets[]
      | select(
          if $asset_filter == "dmg"
          then (.name | endswith(".dmg"))
          elif $asset_filter == "zip"
          then (.name | endswith(".zip"))
          else .name == "appcast.xml"
          end
        )
      | .download_count
    ]
    | add // 0
  ' "$RELEASES_JSON"
}

STABLE_DMG_DOWNLOADS="$(release_total stable dmg)"
STABLE_ZIP_DOWNLOADS="$(release_total stable zip)"
STABLE_FEED_REQUESTS="$(release_total stable feed)"
EDGE_DMG_DOWNLOADS="$(release_total edge dmg)"
EDGE_ZIP_DOWNLOADS="$(release_total edge zip)"
EDGE_FEED_REQUESTS="$(release_total edge feed)"
STABLE_ARTIFACT_DOWNLOADS="$((STABLE_DMG_DOWNLOADS + STABLE_ZIP_DOWNLOADS))"

LATEST_RELEASE_JSON="$(
  jq -c '
    map(select(.draft == false and .prerelease == false))
    | sort_by(.published_at)
    | last // {}
  ' "$RELEASES_JSON"
)"
LATEST_RELEASE_NAME="$(jq -r '.name // .tag_name // "No published release"' <<<"$LATEST_RELEASE_JSON")"
LATEST_RELEASE_URL="$(jq -r '.html_url // "https://github.com/'"$REPOSITORY"'/releases"' <<<"$LATEST_RELEASE_JSON")"
LATEST_RELEASE_DATE="$(jq -r '.published_at // "Unavailable"' <<<"$LATEST_RELEASE_JSON")"
PUBLISHED_RELEASES="$(
  jq '[.[] | select(.draft == false and .prerelease == false)] | length' "$RELEASES_JSON"
)"

STARS="$(jq -r '.stargazers_count // 0' "$REPOSITORY_JSON")"
FORKS="$(jq -r '.forks_count // 0' "$REPOSITORY_JSON")"
WATCHERS="$(jq -r '.subscribers_count // 0' "$REPOSITORY_JSON")"

traffic_value() {
  local file="$1"
  if [[ -s "$file" ]] && jq -e 'type == "object" and (.uniques | type == "number")' "$file" >/dev/null 2>&1; then
    jq -r '.uniques' "$file"
  else
    printf 'Unavailable to this workflow'
  fi
}

UNIQUE_VISITORS="$(traffic_value "$VIEWS_JSON")"
UNIQUE_CLONERS="$(traffic_value "$CLONES_JSON")"

cat <<EOF
# Cadence public usage stats

> Refreshed automatically on **$UPDATED_AT** from GitHub's repository and release APIs.

## Application distribution

| Metric | Count |
|---|---:|
| Stable release artifacts (DMG + ZIP) | $STABLE_ARTIFACT_DOWNLOADS |
| DMG installer downloads | $STABLE_DMG_DOWNLOADS |
| Signed update ZIP fetches | $STABLE_ZIP_DOWNLOADS |
| Stable update-feed requests | $STABLE_FEED_REQUESTS |
| Edge DMG downloads | $EDGE_DMG_DOWNLOADS |
| Edge ZIP fetches | $EDGE_ZIP_DOWNLOADS |
| Edge feed requests | $EDGE_FEED_REQUESTS |
| Published stable/beta releases | $PUBLISHED_RELEASES |
| Unique active Cadence installs | **Not tracked** |

Latest release: [$LATEST_RELEASE_NAME]($LATEST_RELEASE_URL), published $LATEST_RELEASE_DATE.

### Latest-release assets

| Asset | GitHub download count |
|---|---:|
EOF

jq -r '
  .assets // []
  | sort_by(.name)
  | .[]
  | "| [`\(.name)`](\(.browser_download_url)) | \(.download_count) |"
' <<<"$LATEST_RELEASE_JSON"

cat <<EOF

## GitHub repository interest

| Metric | Count |
|---|---:|
| Stars | $STARS |
| Forks | $FORKS |
| Watching | $WATCHERS |
| Unique repository visitors, last 14 days | $UNIQUE_VISITORS |
| Unique repository cloners, last 14 days | $UNIQUE_CLONERS |

## Reading these numbers

- GitHub counts asset fetches, not people. Verification downloads and repeated downloads are included.
- The DMG is the human installer. ZIP fetches include Sparkle updates and direct ZIP downloads.
- Feed requests are update checks, not unique or active users; one installation may check repeatedly.
- Edge assets are replaced on every successful Edge publish, so their counters reset with each build.
- Cadence deliberately sends no launch, dictation, device, or identity telemetry. An active-install count would require a separately designed, disclosed, opt-in analytics system.

This issue is maintained by the [public usage stats workflow](https://github.com/$REPOSITORY/blob/main/.github/workflows/public-stats.yml).
EOF
