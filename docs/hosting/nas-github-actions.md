# Automatic NAS deployment via Tailscale

The existing `Publish Docker image` workflow runs CI, builds amd64/arm64 images
and publishes them to GHCR. After a successful push build on **g96-custom**, it can now
call `deploy-nas.yml` to update an existing Docker Compose installation over SSH
inside Tailscale. Tags, scheduled builds and ordinary manual image builds do not deploy.
To explicitly retry a deployment, run `Publish Docker image` manually with branch
`g96-custom`, `ref=g96-custom`, `push=true` and `deploy=true`. Mismatched build refs
cannot trigger a manual NAS deployment.
No public SSH port or inbound port forwarding is needed.

## NAS prerequisites

- Tailscale connected to your tailnet; ordinary SSH enabled on its tailnet address.
- Bash, Docker and **Docker Compose v2** (`docker compose`) available in the
  noninteractive SSH user's PATH. Set `NAS_USE_SUDO=true` if Docker and project
  files require noninteractive sudo (as on this NAS).
- An existing, running Compose project with services named `web`, `worker`, `db`
  (PostgreSQL), and Redis, like `compose.example.yml`. Both application services
  must use the repository's Dockerfile/entrypoint, with persistent storage.
- Use the **same directory, Compose filename and project name** as your current
  installation, or Compose might create a different project and fresh volumes.
  If you originally used `-p`, configure that same name using `COMPOSE_PROJECT_NAME`
  in the NAS `.env` before enabling deployment.
- A dedicated SSH key authorized for a deployment user with Docker access and
  write permission to the project directory. Docker access is effectively root:
  restrict this account and keep its private key only in GitHub Secrets.
- The workflow sends its short-lived, read-only GitHub registry token over encrypted
  SSH stdin and uses a temporary Docker credentials directory, removed on exit.
  No permanent registry token or manual NAS login is required. The GHCR package
  must grant this repository's Actions access (normally inherited on publication).

Existing `.env`, secrets, Compose configuration and volumes stay on the NAS.
They are not copied from GitHub. Before enabling, verify that they work with your
fork's image, and make an independent backup of PostgreSQL **and uploaded files**.

## GitHub configuration

Create a GitHub environment named **nas** under Settings → Environments. Restrict
its deployment branches to `g96-custom`; optionally require approval (this makes each
deployment wait for approval).

Set these **environment variables** on `nas`:

| Variable | Value |
| --- | --- |
| `NAS_HOST` | `g96-nas` (Tailscale MagicDNS hostname; alternatively `100.115.48.28`) |
| `NAS_USER` | `g96admin` |
| `NAS_PORT` | SSH port; defaults to `22` |
| `NAS_PATH` | `/srv/g96-data/compose/wallet` (existing Compose project directory) |
| `NAS_COMPOSE_FILE` | `compose.yml` |
| `NAS_USE_SUDO` | `true` for this NAS; defaults to `false` |

Set these **environment secrets** on `nas`:

| Secret | Value |
| --- | --- |
| `NAS_SSH_KEY` | Dedicated SSH private key without a passphrase |
| `NAS_KNOWN_HOSTS` | Verified OpenSSH known_hosts entry for `NAS_HOST` and port |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth client secret |

Obtain the NAS host key through a trusted connection and verify its fingerprint
on the NAS. Do not blindly trust an `ssh-keyscan` result. For a nonstandard port,
the known_hosts entry must use `[hostname]:port`.

Create a Tailscale OAuth client with permission to create tagged auth keys and
the tag `tag:github-deploy`. Configure tag ownership and ACLs/grants so that this
tag can reach **only the NAS SSH port**, not your entire LAN. This workflow uses
ordinary OpenSSH, not Tailscale SSH; NAS `authorized_keys` is still required.

Finally set the **repository-level Actions variable** `NAS_DEPLOY_ENABLED=true`
(Settings → Secrets and variables → Actions → Variables). It must be repository
level because the caller checks it before entering the `nas` environment.
Without this switch, existing publishing behavior is unchanged.

## What each deployment does

1. Waits for CI and multi-architecture image publication to succeed.
2. Connects to Tailscale and checks the SSH host key strictly.
3. Pulls the exact commit tag `ghcr.io/<owner>/<repo>:sha-<full-commit>`.
4. Saves a PostgreSQL custom-format dump to `backups/github-deploy/` on the NAS.
   If the dump fails, application containers are not changed. These backups
   contain sensitive financial data: protect them and manage retention/disk space.
5. Stops the worker and updates only `web`, leaving database/Redis/volumes alone.
   **The image entrypoint automatically applies database migrations.** This can
   cause downtime; test releases and ensure backups can be restored.
6. Checks `/up` inside the new web container, then updates the worker. This is a
   web health check, not a guarantee that every background job/integration works.
7. Persists the selected image in `.compose.github-image.yml` on the NAS.

After enabling this integration, manual Compose commands must include the image
override, otherwise the original Compose image (possibly upstream Sure) is used:

```sh
cd /srv/g96-data/compose/wallet
sudo docker compose -f compose.yml -f .compose.github-image.yml ps
```

Adjust the directory and filename to your installation. Do not change the project
name. No `git pull`, volume deletion, pruning or automatic schema rollback occurs.

## Failure and recovery

Check Actions → Publish Docker image → Deploy to NAS. If web startup or migrations
fail, the job fails and the worker remains stopped to avoid running it against a
partially migrated schema. Inspect container logs on the NAS. A failure after web
startup but before worker startup can also leave a partially updated deployment.

The previous override (if any) is stored alongside the database dump. On the first
deployment the original Compose file identifies the old image. Returning to an old
image may require restoring the database too: **do not automatically roll back
images across migrations**. Recover deliberately from a tested backup, then restart
both application services using the intended image override.

Deployments are serialized in GitHub and protected by a NAS directory lock. If a
machine crashes and leaves `.github-deploy.lock`, verify no deployment is still
running before removing that empty directory with `rmdir`.

Set `NAS_DEPLOY_ENABLED=false` to disable future deploys without disabling CI or
image publishing. This change only prepares automation: no NAS is contacted until
the configuration is completed and a new commit is pushed to `g96-custom`.
