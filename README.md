# Frappe v16 on Coolify — Multi-site Docker Compose

Production-oriented starting point for deploying Frappe Framework v16 with ERPNext, HRMS, CRM and additional custom apps on Coolify.

This repository follows the official Frappe Docker layered-image pattern:
https://github.com/frappe/frappe_docker

## Included

- Frappe Framework v16
- ERPNext v16
- HRMS v16
- CRM v16
- Additional apps declared in `apps.json`
- Multiple sites in one Bench / Docker Compose stack
- MariaDB 11.8
- Redis 8.6 cache and queue services
- Backend, Nginx frontend, websocket, short/long workers and scheduler
- Named persistent Docker volumes
- Health checks for MariaDB, Redis, backend, frontend and websocket
- Runtime passwords supplied to containers as Compose secrets

## Repository layout

```text
.
├── Dockerfile
├── apps.json
├── docker-compose.yml
├── .dockerignore
├── .gitignore
├── .env.example
├── README.md
└── scripts/
    ├── create-sites.sh
    ├── main-entrypoint.sh
    └── start.sh
```

## 1. Configure custom apps

Edit `apps.json`. The initial file contains ERPNext, HRMS and CRM on the `version-16` branches.

Add each custom app as another object:

```json
{
  "url": "https://github.com/YOUR-ORG/YOUR-CUSTOM-APP",
  "branch": "version-16"
}
```

Use the actual compatible branch for your app. `INSTALL_APPS` must contain the app's Python module name (usually its Frappe app name), not necessarily the Git repository name.

Example:

```env
INSTALL_APPS=erpnext,hrms,crm,my_custom_app
```

All apps in `INSTALL_APPS` are installed on every hostname in `SITES`. This baseline does not implement different app sets per site.

The supplied manifest uses public Git repositories. For private app repositories, configure a BuildKit SSH/credential secret in your build pipeline; do not put access tokens in `apps.json`, Dockerfile arguments, or repository URLs.

## 2. Coolify environment variables

Create a Docker Compose resource in Coolify and add these variables in its Environment Variables section:

| Variable | Example | Purpose |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `frappe-v16` | Compose project identity |
| `VOLUME_PREFIX` | `frappe-prod` | Stable, unique persistent volume names |
| `FRAPPE_BRANCH` | `version-16` | Frappe branch |
| `FRAPPE_PATH` | `https://github.com/frappe/frappe` | Framework repository |
| `CUSTOM_IMAGE` | `frappe-custom` | Built image name |
| `CUSTOM_TAG` | `v16` | Built image tag |
| `SITES` | `erp.example.com,crm.example.com` | DNS hostnames to provision |
| `INSTALL_APPS` | `erpnext,hrms,crm,my_custom_app` | App module names installed on every site |
| `DB_ROOT_PASSWORD` | generated strong secret | MariaDB root password |
| `ADMIN_PASSWORD` | generated strong secret | Frappe Administrator password |

Optional tuning variables are documented in `.env.example`.

Generate strong, unique passwords. Store them in Coolify only; do not commit `.env` or real credentials to Git.

Compose mounts `DB_ROOT_PASSWORD` and `ADMIN_PASSWORD` as runtime secrets. The MariaDB container reads the root password through `MARIADB_ROOT_PASSWORD_FILE`; the site provisioning script reads the two mounted secret files.

## 3. Deploy in Coolify

1. Push this repository to GitHub.
2. In Coolify, create a Project and choose **Add Resource → Public Repository** (or the appropriate private-repository option).
3. Select this Git repository and the deployment branch.
4. Choose **Docker Compose** as the build pack / deployment type.
5. Set the Base Directory to `/`.
6. Set the Docker Compose file path to `docker-compose.yml`.
7. Add the required environment variables from the table above.
8. Add the domain(s) to the `frontend` service, using internal port `8080`.
9. Deploy.

The Compose file builds the custom image from the repository and uses that image for backend, frontend, websocket, workers, scheduler and provisioning.

### Domains and multi-site routing

For each hostname in `SITES`:

- Create a DNS A/AAAA record pointing to your Coolify server (or a CNAME to the appropriate proxy target).
- Add the hostname to the Coolify domain configuration for the `frontend` service, with container port `8080`.
- Ensure the hostname exactly matches the site name in `SITES`.

Example:

```env
SITES=erp.example.com,crm.example.com,accounts.example.com
```

The frontend passes the incoming Host header to Frappe (`FRAPPE_SITE_NAME_HEADER=$$host`), allowing Frappe to select the matching site. Configure all hostnames on the same frontend service. Enable HTTPS through Coolify's proxy and certificate management.

Do not publish ports 3306, 6379, 8000 or 9000 publicly. Only the Coolify proxy should expose the frontend.

## 4. First deployment and site creation

The `site-setup` service runs after the database, Redis and configurator are healthy. It creates any missing sites in `SITES`, installing every app in `INSTALL_APPS`.

It is intentionally idempotent:
- Existing sites are not recreated.
- Missing apps are installed on existing sites.
- New hostnames added to `SITES` are provisioned on a subsequent deployment.
- A partial site directory without `site_config.json` causes a clear failure instead of being overwritten.

Check the `site-setup` service logs in Coolify. A successful run ends with:

```text
All requested Frappe sites are provisioned.
```

After deployment, log in to each hostname with username `Administrator` and the password stored in `ADMIN_PASSWORD`.

## 5. Persistent data

The Compose file creates four named Docker volumes. Their names use `VOLUME_PREFIX`:

| Volume | Contents |
|---|---|
| `${VOLUME_PREFIX}_db-data` | MariaDB database files |
| `${VOLUME_PREFIX}_sites` | Site configuration, public/private files and assets link |
| `${VOLUME_PREFIX}_logs` | Frappe logs |
| `${VOLUME_PREFIX}_redis-queue-data` | Redis queue persistence |

Keep `VOLUME_PREFIX` stable across redeployments. Changing it creates a new set of empty volumes and can make the existing data appear to be missing.

The Redis cache is intentionally ephemeral. Do not remove or prune the database, sites, logs or queue volumes during normal redeployments.

## 6. Backups — required before production use

Persistent volumes are not backups. Configure an off-server backup destination (S3-compatible object storage, another server, or a managed backup service).

For each site, run a Frappe backup with files from the Bench container:

```bash
bench --site erp.example.com backup --with-files --compress
bench --site crm.example.com backup --with-files --compress
```

Backups are written under each site's private backups directory in the sites volume. Copy them off the Coolify host, encrypt them at rest, and periodically test restoration.

Also schedule consistent MariaDB backups. Do not rely only on copying a live MariaDB data directory. Before upgrades, take a database and files backup and verify it is readable.

## 7. Upgrades and app changes

1. Update app branch/commit references in `apps.json`.
2. Review app compatibility with Frappe v16.
3. Trigger a Coolify redeploy to build the new image.
4. Back up all sites before production upgrades.
5. Run migrations for each site after deploying a changed app image:

```bash
bench --site erp.example.com migrate
bench --site crm.example.com migrate
```

For many sites, automate the migration loop with a controlled release job. Do not assume that merely rebuilding the image migrates existing site databases.

Pin app repositories to tested branches or immutable commits for reproducible releases. Avoid floating branches such as `main` in production unless you deliberately want to track their latest changes.

## 8. Operations and troubleshooting

Useful checks:

```bash
docker compose ps
docker compose logs -f site-setup
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs -f db
docker compose logs -f queue-short queue-long scheduler
```

Common issues:

- **Site not found:** Check the hostname in `SITES`, DNS, Coolify frontend domain mapping and the site's directory.
- **502 from proxy:** Check backend and websocket health, then inspect frontend/backend logs.
- **Site provisioning failed:** Inspect `site-setup` logs and verify database health and secret values.
- **App not found during install:** Ensure the app exists in `apps.json`, its branch is compatible, and its module name is included in `INSTALL_APPS`.
- **Data appears missing after redeploy:** Check that `VOLUME_PREFIX` has not changed and that Coolify has not removed the named volumes.
- **Build fails while fetching a custom app:** Confirm the Git URL and branch; private repositories need build-time credentials.

## 9. Important production notes

- This is a production-oriented Compose baseline, not a substitute for load testing, monitoring, disaster recovery and a tested upgrade procedure.
- Size MariaDB memory, Gunicorn workers and queue workers for the server's available RAM/CPU.
- The default MariaDB and Redis tags follow the current official Frappe Docker v16 examples; review upstream release notes before major upgrades.
- Keep database and Redis services on the private Compose network only.
- Use a unique `VOLUME_PREFIX` for each independent deployment.
- Keep the Coolify deployment branch protected and review changes to `Dockerfile`, `apps.json` and `docker-compose.yml`.

## References

- Official Frappe Docker: https://github.com/frappe/frappe_docker
- Official custom image build guide: https://github.com/frappe/frappe_docker/blob/main/docs/02-setup/02-build-setup.md
- Official production Compose: https://github.com/frappe/frappe_docker/blob/main/compose.yaml
- Coolify Docker Compose guide: https://coolify.io/docs/docs/applications/builds/docker-compose
