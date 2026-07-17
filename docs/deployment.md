---
description: Build PitCrew's MkDocs site in GitHub Actions and publish it to its Cloudflare Pages origin.
---

# Documentation Deployment

PitCrew builds its documentation in GitHub Actions and uploads the generated
`site/` directory to the `pitcrew` Cloudflare Pages project. The canonical
public URL is:

```text
https://www.devleader.ca/projects/pitcrew
```

## Create the Cloudflare Pages project

Create the Direct Upload project once with `main` as the production branch:

```bash
npx wrangler pages project create pitcrew --production-branch main
```

The Pages origin is `https://pitcrew-69b.pages.dev`.

## Add repository secrets

Add these GitHub Actions secrets to `ncosentino/pitcrew`:

| Secret | Purpose |
|--------|---------|
| `CLOUDFLARE_API_TOKEN` | API token with Account - Cloudflare Pages - Edit permission. |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account identifier. |

Do not place either value in `wrangler.toml` or a workflow file.

## Build and publish

Pull requests run a strict MkDocs build without receiving Cloudflare
credentials. Pushes to `main` run the same build and deploy with Wrangler:

```bash
python -m mkdocs build --strict
npx wrangler pages deploy site --project-name=pitcrew --branch=main
```

The `www.devleader.ca/projects/pitcrew` route is maintained by the Dev Leader
project-documentation router after the Pages origin is live.

## Keep the Pages origin out of search results

`docs/_headers` adds `X-Robots-Tag: noindex` to production and preview
`pages.dev` responses. Crawlers can still fetch those URLs, which is required
for them to observe the `noindex` directive, but the origins are not eligible
for search results.

The Dev Leader project-documentation router removes that origin-only header
before returning the canonical `www.devleader.ca/projects/pitcrew` response.
Do not replace this policy with `robots.txt: Disallow`, because blocked
crawlers cannot observe either `noindex` or canonical metadata.

## Configure the GitHub repository

Set the repository homepage to:

```text
https://www.devleader.ca/projects/pitcrew
```

Upload `docs/assets/pitcrew-social-preview.png` under **Settings > General >
Social preview**. The committed asset is 1280x640 pixels, matching GitHub's
recommended repository-preview aspect ratio.
