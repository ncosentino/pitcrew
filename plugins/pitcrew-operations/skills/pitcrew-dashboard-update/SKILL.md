---
name: pitcrew-dashboard-update
description: Update a hosted PitCrew Dashboard or optional support relay, or enable typed capacity controls using release-pinned artifacts and existing identities. Use when the user asks to update, upgrade, or enable dashboard operations.
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
   - optional `deploy/support-relay.compose.yml`
   - optional `deploy/support-relay-caddy.compose.yml`
2. Determine the active Compose project and ingress from `docker compose ls
   --format json` and its config-file list. Continue only when exactly one of the
   Caddy or Cloudflare Tunnel overlays is active.
   Treat the support relay as enabled only when the active config-file list
   contains `deploy/support-relay.compose.yml`. A support-enabled Caddy model
   must also contain `deploy/support-relay-caddy.compose.yml`; Cloudflare must
   not. Stop on partial or unexpected support overlay identity.
   When the deployment is stopped and therefore absent from `compose ls`,
   require the user to name the Compose project, configured ingress, and whether
   support relay is enabled instead of guessing.
3. Read only the current `PITCREW_DASHBOARD_VERSION` value. Never display the
   rest of `.env.hosted`. Use a filtered command that returns only the matching
   version line; never open the file with a content-viewing tool.
   When support relay is enabled, separately read only
   `PITCREW_SUPPORT_RELAY_VERSION`. Never read or display the relay domain,
   bearer, or Dashboard private keys.
4. Use a version explicitly named by the user. Otherwise query the latest
   published, non-draft release from `ncosentino/pitcrew-dashboard`.
5. Verify the target release exists before editing local configuration. Release
   tags use a leading `v`; strip exactly one leading `v` for the GHCR image tag.
   Verify `ghcr.io/ncosentino/pitcrew-dashboard:<image-version>` exists before
   editing `.env.hosted`.
   When support relay is enabled, verify the currently pinned
   `ghcr.io/ncosentino/pitcrew-dashboard-support-relay:<relay-version>` exists.

## Update

Build every Compose command from the same complete model:

```text
docker compose
  --project-name <discovered-project>
  --env-file .env.hosted
  --file docker-compose.hosted.yml
  --file <active-ingress-overlay>
  [--file deploy/support-relay.compose.yml]
  [--file deploy/support-relay-caddy.compose.yml]
```

Include the bracketed files only when discovery proved they are active. Use
this same complete model for every validation, stop, one-off database tool,
private start, rollback, and final start.

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
6. When support relay is enabled, create and verify an independent timestamped
   backup inside `support-relay-data` with the old relay version still pinned.
   Use the same bundled database tool through the `support-relay` service:

   ```text
   backup
   --database /var/lib/pitcrew-support-relay/support-relay.db
   --output /var/lib/pitcrew-support-relay/backups/support-relay-<timestamp>.db
   ```

   Retain its exact path. If backup or verification fails, restart the
   unchanged complete model and stop.
7. Replace only the `PITCREW_DASHBOARD_VERSION` line in `.env.hosted`, retaining
   its previous value for rollback. Write the normalized image version without
   the release tag's leading `v`. When support relay is enabled, verify the
   `PITCREW_SUPPORT_RELAY_VERSION` line is byte-for-byte unchanged.
8. When support relay is enabled, start only `support-relay` while ingress and
   Dashboard remain stopped:

   ```text
   up --detach --no-deps --wait --wait-timeout 120 support-relay
   ```

   Verify its previously pinned image identity, private `/healthz`, dedicated
   volume, internal-only network, and absence of host ports.
9. Start only the dashboard service while ingress remains stopped:

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

When support relay is enabled, also verify the unchanged relay version remains
healthy and that Dashboard uses the internal-only relay network while the
ingress service does not join it.

If this private verification fails:

1. Restore the previous version line.
2. Stop the private new-version dashboard.
3. Run the documented database-tool `restore` command in a one-off
   `--no-deps` dashboard container using the verified pre-update backup.
4. When support relay is enabled, restore its verified pre-update database
   backup with the `support-relay` service because the failed Dashboard may
   have processed durable relay cleanup during private verification.
5. Reapply the previous version with the same scoped pull and
   `up --detach --wait --wait-timeout 120` commands.

The relay image version is not changed during a Dashboard-only update. Retain
both verified backups as incident evidence.

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

## Update the optional support relay

Use this workflow only when the user explicitly requests a relay update and
discovery proved the support overlay is active.

1. Resolve an explicit target release and verify
   `ghcr.io/ncosentino/pitcrew-dashboard-support-relay:<target-version>`
   exists.
2. Validate the complete active model with `config --quiet`.
3. While the old stack is online, pre-pull only `support-relay` with a
   process-scoped `PITCREW_SUPPORT_RELAY_VERSION` override. Clear it in a
   `finally` block.
4. Stop the complete scoped project.
5. Create and verify the relay database backup with the old pinned image.
6. Replace only `PITCREW_SUPPORT_RELAY_VERSION`; keep
   `PITCREW_DASHBOARD_VERSION` and every secret-bearing line unchanged.
7. Start only `support-relay` with `--no-deps --wait`, then verify the target
   image, private `/healthz`, volume, internal-only network, and no host ports.
8. Start only Dashboard and verify private Dashboard health plus the hosted
   ingress contract.
9. Start the complete model and verify public Dashboard and relay health.

If private relay verification fails, restore the previous relay version,
restore the verified relay database with the bundled tool, and restart the old
complete model. After public ingress activation, preserve current relay state
instead of automatically restoring the old database because nodes may have
written new sessions.

## Enable capacity operations

Use this workflow when the user asks to enable dashboard write controls for
worker capacity. This is an opt-in host-service migration of the existing
connector, not a new container.

1. Require the dashboard to be updated to a published release whose assets
   include:
   - `Enable-PitCrewCapacityOperations.ps1`
   - the connector archive and checksum matching the host:
     `linux-x64`, `linux-arm64`, `win-x64`, or `win-arm64`
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
   ceiling. On Linux, invoke it through `sudo pwsh`. On Windows, invoke it
   normally from the interactive host session; the installer requests UAC
   elevation when needed and returns the elevated operation's explicit result.
   If no interactive desktop is available, require the Copilot CLI session to
   already be elevated rather than attempting unattended elevation. The
   installer:
   - verifies the release checksum
   - stops only the exact connector container
   - migrates its identity without displaying it
   - installs and starts the existing connector binary as a native systemd or
     Windows Service
   - restores the connector container if service startup fails
7. Verify:
   - on Linux, `pitcrew-connector.service` is active
   - on Windows, `Get-Service PitCrewConnector` reports `Running`
   - the previous connector container remains stopped
   - the dashboard reports protocol-v3 capacity capability for every selected
     eligible profile
   - the host service remains active through the successful dashboard
     synchronization

Do not manually copy credentials, author service files, build the connector on
the host, mount the Docker socket into the connector container, or leave both
connector processes running. The automated installer currently supports Linux
hosts with systemd and Windows hosts with the Service Control Manager. Report
other operating systems as unsupported instead of improvising.
