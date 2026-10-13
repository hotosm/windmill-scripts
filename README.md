# Windmill Scripts

- Windmill is used to run automated scripts, i.e. a cron schedule within our
  [k8s-infra](https://github.com/hotosm/k8s-infra) cluster.
- This repo keeps our scripts version controlled, and importable into windmill.

## How to sync

```bash
pnpm dlx windmill-cli workspace add hot-staff hot-staff https://tasks.k8s-prod.hotosm.org --token "$WINDMILL_TOKEN"

pnpm dlx windmill-cli workspace list
pnpm dlx windmill-cli workspace switch hot-staff

cd hot-staff
pnpm dlx windmill-cli init

# Subsequent syncs only require this
pnpm dlx windmill-cli sync pull
```

## Infra

Some scripts need AWS setup (networking, IAM) outside Windmill. That lives in
`infra/<script_name>/`, named after the Windmill script it supports, with a
README covering what was created and how to undo it.

- `infra/tm_heigit_export/` → `hot-staff/f/shared/tm_heigit_export.py`
