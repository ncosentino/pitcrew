---
name: pitcrew-dashboard-update
description: Update a hosted PitCrew Dashboard release with its existing .env.hosted and Caddy or Cloudflare Tunnel Compose overlay. Use when the user asks to update or upgrade the PitCrew Dashboard.
license: MIT
---

# PitCrew Dashboard Update

Update only the hosted dashboard Compose project.

Read [operations safety](../../references/safety.md) before running commands.

## Discovery

1. Resolve a user-supplied or current PitCrew Dashboard deployment directory
   containing:
   - `.env.hosted`
   - `docker-compose.hosted.yml`
   - `deploy/caddy.compose.yml`
   - `deploy/cloudflare-tunnel.compose.yml`
2. Determine the active Compose project and ingress from `docker compose ls
   --format json` and its config-file list. Continue only when exactly one of the
   Caddy or Cloudflare Tunnel overlays is active.
   When the deployment is stopped and therefore absent from `compose ls`,
   require the user to name both the Compose project and configured ingress
   instead of guessing.
3. Read only the current `PITCREW_DASHBOARD_VERSION` value. Never display the
   rest of `.env.hosted`. Use a filtered command that returns only the matching
   version line; never open the file with a content-viewing tool.
4. Use a version explicitly named by the user. Otherwise query the latest
   published, non-draft release from `ncosentino/pitcrew-dashboard`.
5. Verify the target release exists before editing local configuration. Release
   tags use a leading `v`; strip exactly one leading `v` for the GHCR image tag.
   Verify `ghcr.io/ncosentino/pitcrew-dashboard:<image-version>` exists before
   editing `.env.hosted`.

## Update

Build every Compose command from the same complete model:

```text
docker compose
  --project-name <discovered-project>
  --env-file .env.hosted
  --file docker-compose.hosted.yml
  --file <active-ingress-overlay>
```

1. Validate the current model with `config --quiet`. Never render the resolved
   Compose configuration.
2. While the old dashboard is still online, pre-pull only the target dashboard
   image by setting `PITCREW_DASHBOARD_VERSION` as a process-scoped environment
   override for this command. Clear the override in a `finally` block. Do not
   edit `.env.hosted` yet:

   ```text
   pull dashboard
   ```

3. Remove the temporary environment override, then stop the complete scoped
   Compose project with `stop`. This creates the maintenance window and prevents
   writes after the backup snapshot.
4. Create a timestamped backup inside the existing `dashboard-data` volume with
   a one-off `run --rm --no-deps` dashboard container using the old version
   still pinned in `.env.hosted`. Set this bundled tool as the entrypoint:

   ```text
   /app/tools/database/PitCrew.Dashboard.DatabaseTool
   ```

   Run:

   ```text
   backup
   --database /var/lib/pitcrew-dashboard/pitcrew-dashboard.db
   --output /var/lib/pitcrew-dashboard/backups/pitcrew-<timestamp>.db
   ```

5. Run the same one-off tool's `verify` command against the backup and retain
   its exact path. If backup or verification fails, restart the unchanged old
   stack and stop the update.
6. Replace only the `PITCREW_DASHBOARD_VERSION` line in `.env.hosted`, retaining
   its previous value for rollback. Write the normalized image version without
   the release tag's leading `v`.
7. Start only the dashboard service while ingress remains stopped:

   ```text
   up --detach --no-deps --wait --wait-timeout 120 dashboard
   ```

Any failure after the maintenance stop but before the target version starts
must restart the unchanged old stack before reporting the failure.

Never use `docker compose down` for a routine update. Never replace the
dashboard with standalone `docker` commands, because that bypasses ingress
dependency coordination.

## Private verification and rollback

Before enabling ingress, verify the private dashboard container uses the
requested image tag, reports healthy, and serves the exact hosted ingress
contract from inside the Compose network:

```text
pitcrew-dashboard-hosted-ingress-v1
```

If this private verification fails:

1. Restore the previous version line.
2. Stop the private new-version dashboard.
3. Run the documented database-tool `restore` command in a one-off
   `--no-deps` dashboard container using the verified pre-update backup.
4. Reapply the previous version with the same scoped pull and
   `up --detach --wait --wait-timeout 120` commands.

After private verification succeeds, enable ingress with the complete model:

```text
up --detach --wait --wait-timeout 120
```

Then verify the public endpoint. Ingress activation is the commit boundary:
once it occurs, do not restore the pre-update database automatically because
clients may have written new data. Report any ingress verification failure as a
partial update requiring diagnosis while preserving the migrated database.

Report private verification failure even when database and image rollback
succeed. Retain the backup for operator inspection. Do not restart Docker, stop
unrelated containers, or prune images.
