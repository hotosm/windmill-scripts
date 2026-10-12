# Windmill Scripts

- Windmill is used to run automated scripts, i.e. a cron schedule within our
  [k8s-infra](https://github.com/hotosm/k8s-infra) cluster.
- This repo keeps our scripts version controlled, and importable into windmill.

## How to sync

```bash
pnpm dlx windmill-cli workspace add hot-staff
# follow instructions if you haven't added token etc yet

pnpm dlx windmill-cli workspace list
pnpm dlx windmill-cli workspace switch hot-staff

cd hot-staff
pnpm dlx windmill-cli init

# Subsequent syncs only require this
pnpm dlx windmill-cli sync pull
```
