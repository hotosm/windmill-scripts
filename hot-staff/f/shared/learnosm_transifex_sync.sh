# shellcheck shell=bash
# Daily: merge hotosm/learnosm@gh-pages into hotosm/learnosm-staging@gh-pages, pull
# translations from Transifex, apply the LearnOSM post-processing and push to staging.
# The push deploys staging.learnosm.org (Actions in the staging repo).
#
# Port of Nick Allen's tx-10pc_pull_git_push.sh.
set -euo pipefail

prod_repo="${1:-hotosm/learnosm}"
staging_repo="${2:-hotosm/learnosm-staging}"
branch="${3:-gh-pages}"
min_perc="${4:-10}"
tx_version="${5:-v1.6.17}"

TX_TOKEN="$(wmill variable get f/shared/transifex_api_key --json | jq -r .value)"
GH_TOKEN="$(wmill variable get f/shared/github-repo-rw --json | jq -r .value)"
export TX_TOKEN

# Git auth via header (same as actions/checkout), so the token never lands in a remote URL.
auth_b64="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
g() { git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth_b64}" "$@"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# --- Transifex CLI ---
case "$(uname -m)" in
  x86_64) tx_arch=amd64 ;;
  aarch64 | arm64) tx_arch=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/transifex/cli/releases/download/${tx_version}/tx-linux-${tx_arch}.tar.gz" \
  | tar -xz -C "$work" tx
TX="$work/tx"

# --- Clone staging: blobless + sparse (only _posts and .tx), skips the ~200 MB of images ---
g clone --quiet --branch "$branch" --filter=blob:none --sparse \
  "https://github.com/${staging_repo}.git" repo
cd repo
git sparse-checkout set _posts .tx
git config user.name "HOT Transifex Bot"
git config user.email "sysadmin@hotosm.org"

# Bring in anything merged straight into prod, so staging doesn't drift
g fetch --quiet "https://github.com/${prod_repo}.git" "$branch"
if ! git merge --quiet --no-edit -m "Merge ${prod_repo}@${branch}" FETCH_HEAD; then
  echo "ERROR: ${prod_repo}@${branch} conflicts with ${staging_repo}@${branch}; resolve by hand:" >&2
  git diff --name-only --diff-filter=U >&2
  exit 1
fi

if [[ ! -f .tx/config ]]; then
  echo ".tx/config not found on ${staging_repo}@${branch}" >&2
  exit 1
fi

# --- tx pull in a scratch dir (config file_filter is translations/..., keep it out of the repo) ---
txdir="$work/tx-pull"
mkdir -p "$txdir/.tx"
cp .tx/config "$txdir/.tx/config"
(cd "$txdir" && "$TX" pull --all --minimum-perc "$min_perc")

# --- Post-processing (ported from tx-10pc_pull_git_push.sh) ---
# Resources that must NOT have their first '>' line stripped.
no_strip_globs=(
  '0170-*' '0200-12-03-*' '0200-12-05-*' '0200-12-23*' '0200-12-31-*'
  '0450-*' '0500-*' '0900-12-04*' '1900-12-31*'
)

# Resource prefixes from .tx/config, e.g. "0450-10-25-id_issues_" for
# "translations/0450-10-25-id_issues_<lang>.md". Slugs contain underscores, so the
# language is whatever follows a known prefix (no hard-coded language list needed).
prefixes=()
while IFS= read -r p; do prefixes+=("$p"); done < <(
  sed -nE 's|^file_filter *= *translations/(.*)<lang>\.md *$|\1|p' .tx/config
)

# Optional hold list: one glob per line matched against the filename, '#' comments allowed.
hold_globs=()
if [[ -f .tx/hold.txt ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && hold_globs+=("$line")
  done < .tx/hold.txt
fi

matches_any() {
  local n="$1" p
  shift
  for p in "$@"; do [[ "$n" == $p ]] && return 0; done
  return 1
}

# Front matter of a file (between the first two '---' lines), or nothing.
front_matter() { [[ "$(head -1 "$1")" == ---* ]] && sed -n '2,/^---/{/^---/!p}' "$1"; }
fm_value() { sed -n "s/^$1: *//p" | head -1; }

rtl_langs=" ar fa he "
valid_layouts=" doc doc-rtl front front-rtl contribute contribute-rtl default status all-chapters "

# Rebuild the front matter of translation $1 (language $2, resource prefix $3) from the
# English source: keep the translated title and a valid translated layout, keep the
# page's current URL; take everything else from English. The body is left byte-for-byte untouched.
fix_front_matter() {
  local f="$1" lang="$2" prefix="$3" en tr_fm en_fm title perm layout line key out
  en="_posts/en/${prefix}en.md"
  # Some English sources use hyphens where the resource name has underscores (id-issues).
  if [[ ! -f "$en" ]]; then en="${prefix%_}"; en="_posts/en/${en//_/-}_en.md"; fi
  [[ -f "$en" ]] || return 1
  tr_fm="$(front_matter "$f")" || return 1
  [[ -n "$tr_fm" ]] || return 1
  en_fm="$(front_matter "$en")"

  title="$(fm_value title <<<"$tr_fm")"
  # Quote titles that aren't valid plain YAML scalars (e.g. "JOSM: Cómo ...").
  if [[ -n "$title" && "$title" != [\"\']* && ( "$title" == *": "* || "$title" == *" #"* || "$title" == [\[\{\&\*\!\|\>\%\@\`-]* ) ]]; then
    title="${title//\\/\\\\}"
    title="\"${title//\"/\\\"}\""
  fi
  # The URL is never taken from Transifex (translators sometimes change it): keep the one the
  # page already has on the site, else use the English one with the language swapped.
  perm=""
  [[ -f "_posts/${lang}/$(basename "$f")" ]] && perm="$(front_matter "_posts/${lang}/$(basename "$f")" | fm_value permalink)"
  [[ "$perm" =~ ^/${lang}/[A-Za-z0-9/._-]*$ ]] || perm="/${lang}/$(fm_value permalink <<<"$en_fm" | sed 's|^/en/||')"
  layout="$(fm_value layout <<<"$tr_fm")"
  if [[ "$valid_layouts" != *" $layout "* ]]; then
    layout="$(fm_value layout <<<"$en_fm")"
    [[ "$rtl_langs" == *" $lang "* && " doc front contribute " == *" $layout "* ]] && layout="${layout}-rtl"
  fi

  out="---"$'\n'
  while IFS= read -r line; do
    key="${line%%:*}"
    case "$key" in
      title) [[ -n "$title" ]] && line="title: ${title}" ;;
      permalink) line="permalink: ${perm}" ;;
      layout) line="layout: ${layout}" ;;
      lang) line="lang: ${lang}" ;;
    esac
    out+="${line}"$'\n'
  done <<<"$en_fm"
  out+="---"$'\n'

  { printf '%s' "$out"; sed '1,/^---/d' "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"
}

shopt -s nullglob
processed=0 held=0 unknown=0 fixed=0 warned=0 replaced=0
synced=()
for f in "$txdir"/translations/*.md; do
  name="$(basename "$f")"
  # Original script only takes 0[1-9]*.md and 19*.md
  [[ "$name" == 0[1-9]*.md || "$name" == 19*.md ]] || continue

  if ((${#hold_globs[@]})) && matches_any "$name" "${hold_globs[@]}"; then
    echo "HOLD     $name"
    held=$((held + 1))
    continue
  fi

  lang="" prefix=""
  for p in "${prefixes[@]}"; do
    if [[ "$name" == "$p"*.md ]]; then
      prefix="$p"
      lang="${name#"$p"}"
      lang="${lang%.md}"
      break
    fi
  done
  [[ "$lang" == en ]] && continue # English is edited directly on staging
  if [[ ! "$lang" =~ ^[a-z]{2,3}(_[A-Za-z]{2,4})?$ ]]; then
    echo "WARNING  could not determine language, skipped: $name"
    unknown=$((unknown + 1))
    continue
  fi

  if ! matches_any "$name" "${no_strip_globs[@]}"; then
    sed -i '0,/^>/{/^>/d;}' "$f"
  fi

  # Translators (and machine translation) often translate the front matter too, e.g.
  # "تخطيط: وثيقة" instead of "layout: doc". Rebuild it from the English source.
  if fix_front_matter "$f" "$lang" "$prefix"; then
    fixed=$((fixed + 1))
  else
    echo "WARNING  could not rebuild front matter, copied as-is: $name"
    warned=$((warned + 1))
  fi

  mkdir -p "_posts/$lang"
  cp "$f" "_posts/$lang/$name"
  synced+=("_posts/$lang/$name")
  processed=$((processed + 1))
done
# Older hand-copied translations sometimes use a non-standard file name (e.g.
# usando-GPS_pt.md for gps_pt.md). When a Transifex file now publishes the same URL,
# remove the old copy, otherwise Jekyll publishes one of the two at random.
declare -A synced_set=()
for f in "${synced[@]}"; do synced_set["$f"]=1; done
perm_of() { front_matter "$1" | fm_value permalink | sed 's|/*$||'; }
declare -A synced_perm=()
for f in "${synced[@]}"; do
  p="$(perm_of "$f")"
  [[ -n "$p" ]] && synced_perm["$p"]="$f"
done
for other in _posts/*/*.md; do
  [[ "$other" == _posts/en/* || -n "${synced_set[$other]:-}" ]] && continue
  [[ "$(basename "$other")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}- ]] || continue # not published by Jekyll
  p="$(perm_of "$other")"
  [[ -n "$p" && -n "${synced_perm[$p]:-}" ]] || continue
  git rm -q "$other"
  echo "REPLACED $other (same URL as ${synced_perm[$p]})"
  replaced=$((replaced + 1))
done

echo "Processed: $processed  Held: $held  Unknown: $unknown  Front matter rebuilt: $fixed  Not rebuilt: $warned  Replaced: $replaced"

# --- Commit & push if anything changed (the prod merge counts) ---
git add -A _posts
git diff --cached --quiet || git commit --quiet -m "Latest translations from Transifex ($(date -u +%F))"
changed_files="$(git diff --name-only "origin/${branch}" HEAD | wc -l)"
pushed=0
if ((changed_files)); then
  g push --quiet origin "HEAD:refs/heads/${branch}"
  echo "Pushed ${staging_repo}@${branch}: ${changed_files} file(s) changed."
  pushed=1
else
  echo "Nothing to push."
fi

echo "{\"processed\": $processed, \"held\": $held, \"unknown\": $unknown, \"replaced\": $replaced, \"changed_files\": $changed_files, \"pushed\": $pushed}"
