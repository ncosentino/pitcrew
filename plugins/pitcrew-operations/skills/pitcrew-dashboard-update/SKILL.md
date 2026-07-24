---
name: pitcrew-dashboard-update
description: Update a hosted PitCrew Dashboard release or enable its typed capacity controls using the release installer and existing connector identity. Use when the user asks to update, upgrade, or enable dashboard operations.
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

## Enable capacity operations

Use this workflow when the user asks to enable dashboard write controls for
worker capacity. This is an opt-in host-service migration of the existing
connector, not a new container.

1. Require the dashboard to be updated to a published release whose assets
   include:
   - `Enable-PitCrewCapacityOperations.ps1`
   - `pitcrew-connector-<version>-linux-x64.tar.gz` and checksum, or
     the equivalent `linux-arm64` assets
2. Resolve the exact PitCrew root and selected profiles. If the user did not
   name a ceiling, use each selected profile's current configured maximum as the
   local ceiling; never invent additional headroom.
3. Resolve the public HTTPS dashboard URL from the active hosted deployment.
   Do not read or display unrelated environment values.
4. Verify exactly one running container has the Compose service label
   `com.docker.compose.service=connector`. Stop if the identity is ambiguous.
5. Download the installer asset from the same published release to a temporary
   path. Never substitute `main`, a branch, or an unversioned raw file.
6. Run the installer as one elevated PowerShell operation with the exact
   release version, PitCrew root, dashboard URL, selected profiles, and local
   ceiling. The installer:
   - verifies the release checksum
   - stops only the exact connector container
   - migrates its identity without displaying it
   - installs and starts the existing connector binary as a systemd service
   - restores the connector container if service startup fails
7. Verify:
   - `pitcrew-connector.service` is active
   - the previous connector container remains stopped
   - connector logs report a successful synchronization without exposing the
     identity or profile environment
   - the dashboard reports protocol-v3 capacity capability for every selected
     eligible profile

Do not manually copy credentials, author service files, build the connector on
the host, mount the Docker socket into the connector container, or leave both
connector processes running. The automated installer currently supports Linux
hosts with systemd; report other hosts as unsupported instead of improvising.
