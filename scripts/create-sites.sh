#!/bin/bash
set -Eeuo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
cd "$BENCH_DIR"

read_secret() {
  local file_path="$1"
  if [[ ! -r "$file_path" ]]; then
    echo "ERROR: Secret file is missing or unreadable: $file_path" >&2
    exit 1
  fi
  cat "$file_path"
}

ADMIN_PASSWORD="$(read_secret "${ADMIN_PASSWORD_FILE:-/run/secrets/admin_password}")"
DB_ROOT_PASSWORD="$(read_secret "${DB_ROOT_PASSWORD_FILE:-/run/secrets/db_root_password}")"

if [[ -z "${SITES:-}" ]]; then
  echo "ERROR: SITES is empty. Set comma-separated site hostnames." >&2
  exit 1
fi

if [[ -z "${INSTALL_APPS:-}" ]]; then
  echo "ERROR: INSTALL_APPS is empty." >&2
  exit 1
fi

IFS=',' read -r -a SITE_LIST <<< "$SITES"
IFS=',' read -r -a APP_LIST <<< "$INSTALL_APPS"

for i in "${!SITE_LIST[@]}"; do
  SITE="$(echo "${SITE_LIST[$i]}" | xargs)"
  [[ -z "$SITE" ]] && continue

  # Restrict hostnames to safe DNS characters.
  if [[ ! "$SITE" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "ERROR: Invalid site hostname: $SITE" >&2
    exit 1
  fi

  echo "Provisioning site: $SITE"

  if [[ -f "sites/$SITE/site_config.json" ]]; then
    echo "Site configuration exists; checking installed apps."
    if ! bench --site "$SITE" list-apps >/tmp/"${SITE}".apps.txt; then
      echo "ERROR: Site directory exists but the site is not accessible: $SITE" >&2
      exit 1
    fi
  else
    if [[ -e "sites/$SITE" ]]; then
      echo "ERROR: $SITE has a partial site directory but no site_config.json."
      echo "Inspect and repair it manually; refusing to overwrite it."
      exit 1
    fi

    NEW_SITE_ARGS=(
      --mariadb-user-host-login-scope="%"
      --admin-password="$ADMIN_PASSWORD"
      --db-root-username=root
      --db-root-password="$DB_ROOT_PASSWORD"
    )

    for app in "${APP_LIST[@]}"; do
      app="$(echo "$app" | xargs)"
      [[ -n "$app" ]] && NEW_SITE_ARGS+=(--install-app "$app")
    done

    bench new-site "$SITE" "${NEW_SITE_ARGS[@]}"
    bench --site "$SITE" list-apps > /tmp/"${SITE}".apps.txt
  fi

  # Install apps added to INSTALL_APPS after the site was first created.
  for app in "${APP_LIST[@]}"; do
    app="$(echo "$app" | xargs)"
    [[ -z "$app" ]] && continue

    if grep -Fxq "$app" /tmp/"${SITE}".apps.txt; then
      echo "  - $app already installed"
    else
      echo "  - Installing $app"
      bench --site "$SITE" install-app "$app"
    fi
  done

  echo "Finished: $SITE"
done

echo "All requested Frappe sites are provisioned."
