---
applyTo: "README.md,docs/**,mkdocs.yml,requirements-docs.txt,.github/workflows/docs.yml"
---

# Documentation

- Keep `docs/index.md` as the canonical documentation map and keep `mkdocs.yml`
  navigation consistent with maintained pages.
- Document current behavior or an explicit target state. Put rollout chronology in
  git history and issue tracking rather than maintained guides.
- Keep complete explanations with one canonical owner. Other pages provide local
  context and link to that owner instead of copying substantial sections.
- Use placeholders in examples. Do not publish credentials, private infrastructure,
  internal hostnames, tenant identifiers, or developer-specific absolute paths.
- Keep public URLs canonical under `https://www.devleader.ca/projects/pitcrew`
  without trailing slashes.
- Preserve `docs/_headers` noindex rules for production and preview Pages origins.
  The canonical router, not the origin, removes that header.
- Keep page descriptions and heading structure compatible with the MkDocs hooks that
  generate structured data and `llms.txt`.
- Update navigation and relative links whenever pages move or are added.
- Run `python -m mkdocs build --strict` for documentation behavior changes.

See [Documentation Deployment](../../docs/deployment.md).
