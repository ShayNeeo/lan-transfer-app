Cloudflare Pages setup for Local Share (webpage)

This repository contains the static front-end in `webpage/build` after running `npm run build`.

Recommended Cloudflare Pages settings:

- Framework preset: None (or "Static site")
- Production branch: `main`
- Build command: `cd webpage && npm ci && npm run build`
- Build output directory: `webpage/build`

Using GitHub Actions deployment (optional):
- I included `.github/workflows/deploy-cloudflare.yml` which uses `cloudflare/pages-action` and expects the following repository secrets:
  - `CF_API_TOKEN` — API token with Pages Deploy permissions
  - `CF_ACCOUNT_ID` — Your Cloudflare account id
  - `CF_PROJECT_NAME` — The Pages project name (for older setups this may be optional)

Manual setup (Cloudflare UI):
1. Go to Cloudflare Pages > Create a project.
2. Connect your GitHub repo and choose the `main` branch.
3. Set the build command and output directory (see above).
4. Save and deploy.

Notes:
- If you prefer Cloudflare to build directly from the repo, use the same build command and output directory.
- If you want the GitHub Action to deploy automatically, create a Pages API token and set the repository secrets accordingly.
