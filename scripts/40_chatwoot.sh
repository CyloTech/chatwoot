#!/bin/bash
set -eo pipefail

RUBY_VERSION="${RUBY_VERSION:-3.4.4}"
NODE_VERSION="${NODE_VERSION:-24.22.1}"
PNPM_VERSION="${PNPM_VERSION:-10.2.0}"
CHATWOOT_ROOT="/home/appbox/chatwoot"
CHATWOOT_SOURCE="/chatwoot"
RUNTIME_ENV="/etc/profile.d/chatwoot-runtime.sh"
APP_USER="appbox"

export HOME=/home/appbox
export USER="${USER:-appbox}"
export NVM_DIR="${NVM_DIR:-/.nvm}"

source "/usr/share/rvm/scripts/rvm"
\. "${NVM_DIR}/nvm.sh"
nvm use "${NODE_VERSION}"

export PORT="${PORT:-3000}"
export RAILS_ENV="${RAILS_ENV:-production}"
export NODE_ENV="${NODE_ENV:-production}"
export RAILS_LOG_TO_STDOUT="${RAILS_LOG_TO_STDOUT:-true}"
export RAILS_SERVE_STATIC_FILES="${RAILS_SERVE_STATIC_FILES:-true}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096 --openssl-legacy-provider}"
export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"
export GEM_HOME="/usr/share/rvm/gems/ruby-${RUBY_VERSION}"
export GEM_PATH="/usr/share/rvm/gems/ruby-${RUBY_VERSION}:/usr/share/rvm/gems/ruby-${RUBY_VERSION}@global"
export PATH="/home/appbox/.local/share/pnpm:/.local/share/pnpm:/root/.local/share/pnpm:${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:/usr/share/rvm/rubies/ruby-${RUBY_VERSION}/bin:${GEM_HOME}/bin:${PATH}"

echo "**************************************************************"
echo "*                    Installing Chatwoot                     *"
echo "**************************************************************"

write_runtime_env() {
    cat > "${RUNTIME_ENV}" <<EOF
export RUBY_VERSION="${RUBY_VERSION}"
export NODE_VERSION="${NODE_VERSION}"
export PNPM_VERSION="${PNPM_VERSION}"
export HOME="/home/appbox"
export USER="appbox"
export PORT="3000"
export RAILS_ENV="production"
export NODE_ENV="production"
export RAILS_LOG_TO_STDOUT="true"
export RAILS_SERVE_STATIC_FILES="true"
export NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider"
export BUNDLE_WITHOUT="development:test"
export GEM_HOME="/usr/share/rvm/gems/ruby-${RUBY_VERSION}"
export GEM_PATH="/usr/share/rvm/gems/ruby-${RUBY_VERSION}:/usr/share/rvm/gems/ruby-${RUBY_VERSION}@global"
export NVM_DIR="${NVM_DIR}"
export PATH="/home/appbox/.local/share/pnpm:/.local/share/pnpm:/root/.local/share/pnpm:${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:/usr/share/rvm/rubies/ruby-${RUBY_VERSION}/bin:/usr/share/rvm/gems/ruby-${RUBY_VERSION}/bin:\${PATH}"
EOF
}

run_as_appbox() {
    local env_vars=(
        "HOME=/home/appbox"
        "USER=appbox"
        "RUBY_VERSION=${RUBY_VERSION}"
        "NODE_VERSION=${NODE_VERSION}"
        "PNPM_VERSION=${PNPM_VERSION}"
        "NVM_DIR=${NVM_DIR}"
        "PORT=${PORT}"
        "RAILS_ENV=${RAILS_ENV}"
        "NODE_ENV=${NODE_ENV}"
        "RAILS_LOG_TO_STDOUT=${RAILS_LOG_TO_STDOUT}"
        "RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}"
        "NODE_OPTIONS=${NODE_OPTIONS}"
        "BUNDLE_WITHOUT=${BUNDLE_WITHOUT}"
        "GEM_HOME=${GEM_HOME}"
        "GEM_PATH=${GEM_PATH}"
    )

    [[ -n "${EMAIL:-}" ]] && env_vars+=("EMAIL=${EMAIL}")
    [[ -n "${PASSWORD:-}" ]] && env_vars+=("PASSWORD=${PASSWORD}")
    [[ -n "${COMPANY:-}" ]] && env_vars+=("COMPANY=${COMPANY}")
    [[ -n "${NAME:-}" ]] && env_vars+=("NAME=${NAME}")

    sudo -u "${APP_USER}" env "${env_vars[@]}" bash -lc "source /usr/share/rvm/scripts/rvm && source ${RUNTIME_ENV} && cd ${CHATWOOT_ROOT} && $*"
}

start_postgres_for_setup() {
    source "${PG_APP_HOME}/functions.sh"
    rm -f "${PG_DATADIR}/postmaster.pid"
    sudo -u "${PG_USER}" "${PG_BINDIR}/pg_ctl" -D "${PG_DATADIR}" -w start

    echo "Waiting for postgres to become ready..."
    until pg_isready -h 127.0.0.1 -p 5432 -U "${PG_USER}" -d postgres >/dev/null 2>&1; do
        sleep 2
    done
}

stop_postgres_for_setup() {
    sudo -u "${PG_USER}" "${PG_BINDIR}/pg_ctl" -D "${PG_DATADIR}" -m fast -w stop >/dev/null 2>&1 || true
    rm -f "${PG_DATADIR}/postmaster.pid"
}

start_redis_for_setup() {
    sudo -u "${APP_USER}" /usr/bin/redis-server /home/appbox/config/redis/redis.conf &
    REDIS_PID=$!
}

stop_redis_for_setup() {
    redis-cli -h 127.0.0.1 -p 6379 shutdown nosave >/dev/null 2>&1 || true
    if [[ -n "${REDIS_PID:-}" ]]; then
        kill "${REDIS_PID}" 2>/dev/null || true
        wait "${REDIS_PID}" 2>/dev/null || true
    fi
}

ensure_database_user() {
    sudo -s -u "${PG_USER}" psql -d postgres <<'SQL'
DO
$do$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'chatwoot') THEN
      CREATE ROLE chatwoot LOGIN CREATEDB PASSWORD 'chatwoot';
   END IF;
END
$do$;
ALTER ROLE chatwoot WITH SUPERUSER PASSWORD 'chatwoot';
SQL
}

sync_chatwoot_source() {
    local had_existing_env=0
    local had_storage=0
    local had_public_uploads=0

    install -d -o "${APP_USER}" -g "${APP_USER}" "${CHATWOOT_ROOT}"
    rm -rf /tmp/chatwoot-storage /tmp/chatwoot-public-uploads

    if [[ -f "${CHATWOOT_ROOT}/.env" ]]; then
        had_existing_env=1
        cp "${CHATWOOT_ROOT}/.env" /tmp/chatwoot.env
    fi
    if [[ -d "${CHATWOOT_ROOT}/storage" ]]; then
        had_storage=1
        mv "${CHATWOOT_ROOT}/storage" /tmp/chatwoot-storage
    fi
    if [[ -d "${CHATWOOT_ROOT}/public/uploads" ]]; then
        had_public_uploads=1
        mkdir -p /tmp/chatwoot-public
        mv "${CHATWOOT_ROOT}/public/uploads" /tmp/chatwoot-public-uploads
    fi

    rm -rf "${CHATWOOT_ROOT:?}/"*
    rm -rf "${CHATWOOT_ROOT:?}/".[!.]* "${CHATWOOT_ROOT:?}/"..?* 2>/dev/null || true
    sudo -u "${APP_USER}" cp -R --no-preserve=ownership "${CHATWOOT_SOURCE}/." "${CHATWOOT_ROOT}/"

    if [[ "${had_existing_env}" -eq 1 ]]; then
        cp /tmp/chatwoot.env "${CHATWOOT_ROOT}/.env"
    fi
    if [[ "${had_storage}" -eq 1 ]]; then
        rm -rf "${CHATWOOT_ROOT}/storage"
        mv /tmp/chatwoot-storage "${CHATWOOT_ROOT}/storage"
    fi
    if [[ "${had_public_uploads}" -eq 1 ]]; then
        mkdir -p "${CHATWOOT_ROOT}/public"
        rm -rf "${CHATWOOT_ROOT}/public/uploads"
        mv /tmp/chatwoot-public-uploads "${CHATWOOT_ROOT}/public/uploads"
    fi
}

ensure_runtime_permissions() {
    install -d -o "${APP_USER}" -g "${APP_USER}" /home/appbox/config /home/appbox/logs
    install -d -o "${APP_USER}" -g "${APP_USER}" "${CHATWOOT_ROOT}/log" "${CHATWOOT_ROOT}/tmp" "${CHATWOOT_ROOT}/storage" "${CHATWOOT_ROOT}/public/uploads"
    [[ -f "${CHATWOOT_ROOT}/.env" ]] && chown "${APP_USER}:${APP_USER}" "${CHATWOOT_ROOT}/.env"
    chown -R "${APP_USER}:${APP_USER}" /home/appbox/config /home/appbox/logs "${CHATWOOT_ROOT}/log" "${CHATWOOT_ROOT}/tmp" "${CHATWOOT_ROOT}/storage" "${CHATWOOT_ROOT}/public/uploads"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local escaped

    escaped=$(printf '%s' "${value}" | sed -e 's/[\/&]/\\&/g')
    if grep -q "^#\?${key}=" "${CHATWOOT_ROOT}/.env"; then
        sed -i -E "s/^#?${key}=.*/${key}=${escaped}/" "${CHATWOOT_ROOT}/.env"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${CHATWOOT_ROOT}/.env"
    fi
}

ensure_env_file() {
    local secret

    if [[ ! -f "${CHATWOOT_ROOT}/.env" ]]; then
        secret=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 63)
        cp "${CHATWOOT_ROOT}/.env.example" "${CHATWOOT_ROOT}/.env"
        set_env_value SECRET_KEY_BASE "${secret}"
    fi

    set_env_value REDIS_URL "redis://localhost:6379"
    set_env_value POSTGRES_HOST "localhost"
    set_env_value POSTGRES_PORT "5432"
    set_env_value POSTGRES_DATABASE "chatwoot_production"
    set_env_value POSTGRES_USERNAME "chatwoot"
    set_env_value POSTGRES_PASSWORD "chatwoot"
    set_env_value RAILS_ENV "production"
    set_env_value NODE_ENV "production"
    set_env_value RAILS_LOG_TO_STDOUT "true"
    set_env_value RAILS_SERVE_STATIC_FILES "true"
    set_env_value ENABLE_ACCOUNT_SIGNUP "false"
    set_env_value ACTIVE_STORAGE_SERVICE "local"
    set_env_value INSTALLATION_ENV "cylo_appbox"
    set_env_value FRONTEND_URL "${URL:-https://${VIRTUAL_HOST:-localhost}}"

    [[ -n "${MAILER_SENDER_EMAIL:-}" ]] && set_env_value MAILER_SENDER_EMAIL "${MAILER_SENDER_EMAIL}"
    [[ -n "${SMTP_PORT:-}" ]] && set_env_value SMTP_PORT "${SMTP_PORT}"
    [[ -n "${SMTP_DOMAIN:-}" ]] && set_env_value SMTP_DOMAIN "${SMTP_DOMAIN}"
    [[ -n "${SMTP_ADDRESS:-}" ]] && set_env_value SMTP_ADDRESS "${SMTP_ADDRESS}"
    [[ -n "${SMTP_USERNAME:-}" ]] && set_env_value SMTP_USERNAME "${SMTP_USERNAME}"
    [[ -n "${SMTP_PASSWORD:-}" ]] && set_env_value SMTP_PASSWORD "${SMTP_PASSWORD}"
    [[ -n "${SMTP_AUTHENTICATION:-}" ]] && set_env_value SMTP_AUTHENTICATION "${SMTP_AUTHENTICATION}"
    [[ -n "${SMTP_ENABLE_STARTTLS_AUTO:-}" ]] && set_env_value SMTP_ENABLE_STARTTLS_AUTO "${SMTP_ENABLE_STARTTLS_AUTO}"
    return 0
}

wait_for_chatwoot() {
    echo "Waiting for Chatwoot to respond..."
    until curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; do
        sleep 2
    done
}

seed_initial_admin() {
    if [[ -z "${EMAIL:-}" || -z "${PASSWORD:-}" || -z "${COMPANY:-}" ]]; then
        echo "Admin seed values not supplied; skipping onboarding seed."
        return
    fi
    if [[ ! "${PASSWORD}" =~ [[:upper:]] || ! "${PASSWORD}" =~ [[:lower:]] || ! "${PASSWORD}" =~ [[:digit:]] || ! "${PASSWORD}" =~ [^[:alnum:]] || ${#PASSWORD} -lt 8 ]]; then
        echo "Admin password must be at least 8 characters and include upper, lower, number, and special characters."
        return 1
    fi

    cat > /tmp/chatwoot_seed_admin.rb <<'RUBY'
account = Account.first_or_create!(name: ENV.fetch('COMPANY'))
user = User.find_or_initialize_by(email: ENV.fetch('EMAIL'))
user.name = ENV.fetch('NAME', ENV.fetch('EMAIL'))
user.password = ENV.fetch('PASSWORD') if user.new_record?
user.password_confirmation = ENV.fetch('PASSWORD') if user.new_record?
user.confirmed_at ||= Time.current if user.respond_to?(:confirmed_at)
user.type = 'SuperAdmin' if defined?(SuperAdmin) && user.respond_to?(:type=)
user.save!
AccountUser.find_or_create_by!(account: account, user: user) do |account_user|
  account_user.role = :administrator
end
InstallationConfig.find_or_create_by!(name: 'CHATWOOT_INSTALLATION_ONBOARDING') do |config|
  config.value = false
end if defined?(InstallationConfig)
RUBY

    run_as_appbox "bundle exec rails runner /tmp/chatwoot_seed_admin.rb"
    rm -f /tmp/chatwoot_seed_admin.rb
}

run_chatwoot_prepare() {
    run_as_appbox "bundle exec rails db:chatwoot_prepare"
}

create_services() {
    mkdir -p /etc/service/chatwoot-web /etc/service/chatwoot-worker

    cat > /etc/service/chatwoot-web/run <<'EOF'
#!/bin/bash
set -e
export HOME=/home/appbox
export USER=appbox
source /usr/share/rvm/scripts/rvm
source /etc/profile.d/chatwoot-runtime.sh
source "${NVM_DIR}/nvm.sh"
nvm use "${NODE_VERSION}" >/dev/null
cd /home/appbox/chatwoot
rm -f tmp/pids/server.pid
exec /bin/su -s /bin/bash appbox -c 'export HOME=/home/appbox USER=appbox && source /usr/share/rvm/scripts/rvm && source /etc/profile.d/chatwoot-runtime.sh && cd /home/appbox/chatwoot && bundle exec rails server -p "${PORT}" -b 0.0.0.0 -e "${RAILS_ENV}"'
EOF

    cat > /etc/service/chatwoot-worker/run <<'EOF'
#!/bin/bash
set -e
export HOME=/home/appbox
export USER=appbox
source /usr/share/rvm/scripts/rvm
source /etc/profile.d/chatwoot-runtime.sh
source "${NVM_DIR}/nvm.sh"
nvm use "${NODE_VERSION}" >/dev/null
cd /home/appbox/chatwoot
exec /bin/su -s /bin/bash appbox -c 'export HOME=/home/appbox USER=appbox && source /usr/share/rvm/scripts/rvm && source /etc/profile.d/chatwoot-runtime.sh && cd /home/appbox/chatwoot && bundle exec sidekiq -C config/sidekiq.yml'
EOF

    chmod +x /etc/service/chatwoot-web/run /etc/service/chatwoot-worker/run
}

main() {
    write_runtime_env
    mkdir -p /home/appbox/config /home/appbox/logs/redis /home/appbox/logs/postgresql
    touch /home/appbox/logs/redis/redis-server.log

    if [[ ! -f /etc/chatwoot_installed || ! -f "${CHATWOOT_ROOT}/.env" ]]; then
        echo "Running Chatwoot first-run setup/update tasks..."
        sync_chatwoot_source
        ensure_env_file
        ensure_runtime_permissions

        trap 'stop_redis_for_setup; stop_postgres_for_setup' EXIT
        start_redis_for_setup
        start_postgres_for_setup
        ensure_database_user
        run_chatwoot_prepare
        seed_initial_admin
        trap - EXIT
        stop_redis_for_setup
        stop_postgres_for_setup
        touch /etc/chatwoot_installed
    else
        echo "Chatwoot is already installed; refreshing application code and running migrations."
        sync_chatwoot_source
        ensure_env_file
        ensure_runtime_permissions

        trap 'stop_redis_for_setup; stop_postgres_for_setup' EXIT
        start_redis_for_setup
        start_postgres_for_setup
        run_chatwoot_prepare
        trap - EXIT
        stop_redis_for_setup
        stop_postgres_for_setup
    fi

    ensure_runtime_permissions
    create_services
}

main "$@"
