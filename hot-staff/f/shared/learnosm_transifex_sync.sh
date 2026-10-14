# shellcheck shell=bash
# Daily: pull LearnOSM translations from Transifex, apply the LearnOSM post-processing,
# and force-push the result to the `transifex-sync` branch of hotosm/learnosm
# (rebuilt from gh-pages on every run, so it is always "prod + pending translations").
# Then trigger the staging deploy (hotosm/learnosm-staging -> staging.learnosm.org).
#
# Port of Nick Allen's tx-10pc_pull_git_push.sh, made stateless.
# Plan: TRANSLATION_STAGING_PLAN.md in hotosm/learnosm.
set -euo pipefail

repo="${1:-hotosm/learnosm}"
base_branch="${2:-gh-pages}"
sync_branch="${3:-transifex-sync}"
min_perc="${4:-10}"
staging_repo="${5:-hotosm/learnosm-staging}"
tx_version="${6:-v1.6.17}"

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

# --- Clone prod: shallow + sparse (only _posts and .tx), skips the ~200 MB of images ---
g clone --quiet --depth 1 --branch "$base_branch" --filter=blob:none --sparse \
  "https://github.com/${repo}.git" repo
cd repo
git sparse-checkout set _posts .tx
git config user.name "HOT Transifex Bot"
git config user.email "sysadmin@hotosm.org"
git checkout --quiet -B "$sync_branch"
base_sha="$(git rev-parse HEAD)"

if [[ ! -f .tx/config ]]; then
  echo ".tx/config not found on ${repo}@${base_branch}" >&2
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
  if [[ "$lang" != en ]]; then
    if fix_front_matter "$f" "$lang" "$prefix"; then
      fixed=$((fixed + 1))
    else
      echo "WARNING  could not rebuild front matter, copied as-is: $name"
      warned=$((warned + 1))
    fi
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

# --- Commit & push only if something changed ---
git add -A _posts
remote_sha="$(g ls-remote --heads origin "$sync_branch" | cut -f1)"
pushed=0
changed_files=0

if git diff --cached --quiet; then
  echo "No differences from ${base_branch}."
  if [[ -n "$remote_sha" ]]; then
    # Everything merged (or reverted): remove the branch. This also closes any open PR.
    g push --quiet origin --delete "$sync_branch"
    echo "Deleted stale ${sync_branch}."
    pushed=1
  fi
else
  git commit --quiet -m "Latest translations from Transifex ($(date -u +%F))"
  changed_files="$(git diff --name-only "$base_sha" HEAD | wc -l)"
  same=0
  if [[ -n "$remote_sha" ]]; then
    g fetch --quiet --depth 1 origin "$sync_branch"
    remote_tree="$(git rev-parse 'FETCH_HEAD^{tree}')"
    # Read the parent from the commit object (FETCH_HEAD^ is unavailable in a shallow fetch).
    remote_parent="$(git cat-file -p FETCH_HEAD | sed -n 's/^parent //p' | head -1)"
    # Same content on the same gh-pages base: skip, to avoid daily noise in the PR timeline.
    [[ "$(git rev-parse 'HEAD^{tree}')" == "$remote_tree" && "$remote_parent" == "$base_sha" ]] && same=1
  fi
  if ((same)); then
    echo "${sync_branch} already up to date."
  else
    g push --quiet --force origin "HEAD:refs/heads/${sync_branch}"
    echo "Pushed ${sync_branch}: ${changed_files} file(s) differ from ${base_branch}."
    pushed=1
  fi
fi

# --- Trigger staging deploy ---
# Every run, not only when the branch changed: staging also picks up gh-pages merges and
# staging/* branches in the source repo, which this script can't see.
# repository_dispatch only needs Contents: write on the staging repo (workflow_dispatch
# would need Actions: write).
curl -sS --fail-with-body -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${staging_repo}/dispatches" \
  -d '{"event_type":"transifex-sync"}'
echo "Staging deploy triggered."

echo "{\"processed\": $processed, \"held\": $held, \"unknown\": $unknown, \"replaced\": $replaced, \"changed_files\": $changed_files, \"pushed\": $pushed}"
