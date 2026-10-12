# shellcheck shell=bash
set -euo pipefail

interval="${1:-24}"
project="${2:-}"
template="${3:-}"

export OEX_DATA_DIR=/data

command -v osmium >/dev/null || {
  apt-get update && apt-get install -y --no-install-recommends osmium-tool
}

creds_json="$(wmill variable get f/shared/oex_creds --json | jq -r .value)"
while IFS= read -r line; do
  export "${line%%=*}=${line#*=}"
done < <(jq -r 'to_entries[] | "\(.key)=\(.value|tostring)"' <<< "$creds_json")

cd /data/osm-country-exports 2>/dev/null || {
  git clone https://github.com/hotosm/osm-country-exports /data/osm-country-exports
  cd /data/osm-country-exports
}
git pull --ff-only
uv sync --frozen

if [ -n "$project" ]; then
  args=(--sandbox --extract --export --project "$project")
else
  args=(--sandbox --extract --export --interval "$interval")
fi

if [ -n "$template" ]; then
  template_path="configs/${template%.yaml}.yaml"
  [ -f "$template_path" ] || { echo "no such template: $template_path" >&2; exit 2; }
  args+=(--template "$template_path")
fi

./scripts/tm_configs.py "${args[@]}"