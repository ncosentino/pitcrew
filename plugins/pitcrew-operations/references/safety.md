# PitCrew Operations Safety Contract

Apply these rules to every PitCrew operations skill.

1. Work only in a PitCrew or PitCrew Dashboard directory supplied by the user,
   the current working directory, or one of its descendants. Do not search
   unrelated local repositories or scan an entire drive for installations.
2. Never display, return, log, or copy the contents of `.env`, `.env.*`,
   `.env.hosted`, secret files, connector identities, or registration tokens.
   Never run `docker compose config` without `--quiet`, because rendered Compose
   output can include resolved secret values.
3. Never restart Docker Desktop, the Docker service, the Docker daemon, or the
   host. Application and profile updates do not require a daemon restart.
4. Never run `docker system prune`, broad container stop/remove pipelines,
   name-based cleanup, or cleanup outside PitCrew's exact Compose project and
   labels.
5. Never use `git reset --hard`, discard local changes, force-checkout over a
   dirty worktree, or rewrite repository history.
6. Stop on ambiguous profile, installation, release, ingress, or project
   identity. Ask for the missing path or name conversationally instead of
   guessing.
7. Validate the complete operation before changing state. Afterward, verify the
   requested outcome rather than treating a successful command exit as proof.
8. Surface partial completion and failures explicitly. Do not hide an update
   failure behind a rollback or other success-shaped fallback.
