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
staging_workflow="${6:-deploy.yml}"
tx_version="${7:-v1.6.17}"

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

shopt -s nullglob
processed=0 held=0 unknown=0
for f in "$txdir"/translations/*.md; do
  name="$(basename "$f")"
  # Original script only takes 0[1-9]*.md and 19*.md
  [[ "$name" == 0[1-9]*.md || "$name" == 19*.md ]] || continue

  if ((${#hold_globs[@]})) && matches_any "$name" "${hold_globs[@]}"; then
    echo "HOLD     $name"
    held=$((held + 1))
    continue
  fi

  lang=""
  for p in "${prefixes[@]}"; do
    if [[ "$name" == "$p"*.md ]]; then
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

  # Translators sometimes edit the front matter: force `lang:` to the file's language,
  # rewrite `/en/...` permalinks and restore a missing slash ("/zh_CNjosm/" -> "/zh_CN/josm/").
  if [[ "$lang" != en ]]; then
    if [[ "$(head -1 "$f")" == ---* ]]; then
      sed -i -E "2,/^---/{
        s|^lang:.*|lang: ${lang}|
        s|^permalink: */en/|permalink: /${lang}/|
        s|^(permalink: */${lang})([a-z])|\\1/\\2|
      }" "$f"
    fi
    for key in layout permalink lang; do
      sed -n '2,/^---/p' "$f" | grep -q "^${key}:" ||
        echo "WARNING  front matter has no '${key}:' (fix in Transifex): $name"
    done
  fi

  mkdir -p "_posts/$lang"
  cp "$f" "_posts/$lang/$name"
  processed=$((processed + 1))
done
echo "Processed: $processed  Held: $held  Unknown: $unknown"

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
curl -fsS -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${staging_repo}/actions/workflows/${staging_workflow}/dispatches" \
  -d '{"ref":"main"}'
echo "Staging deploy triggered."

echo "{\"processed\": $processed, \"held\": $held, \"unknown\": $unknown, \"changed_files\": $changed_files, \"pushed\": $pushed}"
