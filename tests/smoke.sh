#!/usr/bin/env bash
# Image smoke test (needs Docker; sends nothing to Appbox, because api.cylo.net
# resolves to the container itself):
#   - image: Node and Ruby match the versions the Chatwoot release pins;
#   - fresh install on an empty /home/appbox owned by UID 1000, as Appbox
#     mounts it: Chatwoot, Redis and PostgreSQL start while the installed
#     callback cannot reach the API, /api reports the manifest version, the
#     seeded admin signs in as a SuperAdmin and administrator of the company
#     account, account signup is closed, and the password is not in the log;
#   - restart: Chatwoot comes back without running first-time setup again and
#     keeps a contact created before the restart;
#   - moduser.sh: the new password signs in and the old one is refused;
#   - update (with a previous image): the admin and a contact created by the
#     previous image are still there after a container of this image starts
#     on the same /home/appbox and migrates the database.
#
# Usage: tests/smoke.sh <image> [<previous-image>]
set -Eeuo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: tests/smoke.sh <image> [<previous-image>]" >&2
    exit 2
fi
image=$1
previous=${2:-}
want_version=$(sed -n 's/^  version: "\(.*\)"$/\1/p' appbox.yml)

run_id="cwsmoke-$$-${RANDOM}"
containers=()
volumes=()
scratch=$(mktemp -d)
cleanup() {
    local c v
    for c in "${containers[@]+"${containers[@]}"}"; do docker rm -f "${c}" >/dev/null 2>&1 || true; done
    for v in "${volumes[@]+"${volumes[@]}"}"; do docker volume rm "${v}" >/dev/null 2>&1 || true; done
    rm -rf "${scratch}"
}
trap cleanup EXIT

random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Throwaway test account. The passwords meet the install field's rules and
# are hex apart from fixed characters, so they are safe to mask with sed.
EMAIL="smoke$(random_hex 4)@example.test"
PASSWORD="Smoke-$(random_hex 12)A1"
NEW_PASSWORD="Reset-$(random_hex 12)B2"
COMPANY="Smoke Co $(random_hex 2)"
NAME="Smoke Admin"
export EMAIL PASSWORD COMPANY NAME

masked_logs() {
    docker logs "$1" 2>&1 | sed -e "s/${PASSWORD}/<password>/g" -e "s/${NEW_PASSWORD}/<new-password>/g"
}

fail() {
    echo "FAIL $1" >&2
    if [[ -n "${2:-}" ]]; then
        masked_logs "$2" | tail -60 >&2
    fi
    exit 1
}
pass() { echo "ok   $*"; }

# Appbox bind-mounts an empty directory owned by UID 1000 at /home/appbox. A
# volume-nocopy volume starts empty like that, instead of being filled from
# the image.
new_volume() {
    docker volume create "$1" >/dev/null
    volumes+=("$1")
    docker run --rm --mount "type=volume,src=$1,dst=/v,volume-nocopy=true" \
        --entrypoint chown "${image}" 1000:1000 /v
}

# start <name> <image> <volume> [<docker run options>...]
# Resources follow the catalogue (6 GB, no swap, 2 GB reservation, init).
start() {
    local name=$1 img=$2 volume=$3
    shift 3
    docker run -d --name "${name}" --init \
        --memory 6g --memory-swap 6g --memory-reservation 2g \
        --add-host api.cylo.net:127.0.0.1 \
        -e EMAIL -e PASSWORD -e COMPANY -e NAME \
        -e URL=http://localhost:3000 -e VIRTUAL_PORT=3000 -e INSTANCE_ID=smoke \
        --mount "type=volume,src=${volume},dst=/home/appbox,volume-nocopy=true" \
        "$@" "${img}" >/dev/null
    containers+=("${name}")
}

# wait_api <container>: first boot copies the source and loads the schema,
# so allow up to 20 minutes.
wait_api() {
    local i
    for ((i = 0; i < 240; i++)); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$1")" == true ]] || fail "$1: container stopped" "$1"
        if docker exec "$1" curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/api 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    fail "$1: /api did not answer within 20 minutes" "$1"
}

check() {
    local container=$1
    shift
    docker exec -i -e EMAIL -e PASSWORD -e COMPANY "${container}" python3 -I - "$@" <tests/chatwoot_check.py \
        || fail "${container}: $* check" "${container}"
}

schema_version() {
    docker exec "$1" sudo -u appbox psql -d chatwoot_production -Atc 'SELECT max(version) FROM schema_migrations'
}

log_count() { masked_logs "$1" | grep -cF "$2" || true; }

no_credentials_logged() {
    if docker logs "$1" 2>&1 | grep -qF -e "${PASSWORD}" -e "${NEW_PASSWORD}"; then
        fail "$1: a password appears in the container log"
    fi
    pass "$1: no password in the container log"
}

# --- image -----------------------------------------------------------------------
toolchain=$(docker run --rm --entrypoint bash "${image}" -c \
    'printf "%s %s %s %s\n" "${NODE_VERSION}" "$(cat /chatwoot/.nvmrc)" "${RUBY_VERSION}" "$(cat /chatwoot/.ruby-version)"')
read -r node_env node_pin ruby_env ruby_pin <<<"${toolchain}"
[[ "${node_env}" == "${node_pin}" ]] || fail "image Node ${node_env}, Chatwoot pins ${node_pin}"
[[ "${ruby_env}" == "${ruby_pin}" ]] || fail "image Ruby ${ruby_env}, Chatwoot pins ${ruby_pin}"
pass "image Node ${node_env} and Ruby ${ruby_env} match the Chatwoot pins"

# --- fresh install ---------------------------------------------------------------
fresh="${run_id}-fresh"
new_volume "${fresh}"
start "${fresh}" "${image}" "${fresh}"
wait_api "${fresh}"
[[ "$(log_count "${fresh}" 'installed callback got HTTP 000, retrying')" -ge 1 ]] \
    || fail "the installed callback did not run in the background" "${fresh}"
pass "fresh install started while the installed callback was still retrying"

got_version=$(check "${fresh}" version)
[[ "${got_version}" == "${want_version}" ]] || fail "/api reports ${got_version}, manifest says ${want_version}"
pass "/api reports ${got_version} with Redis and PostgreSQL ok"
check "${fresh}" login
check "${fresh}" signups-closed
check "${fresh}" create-contact "Restart Contact"
no_credentials_logged "${fresh}"

# --- restart ---------------------------------------------------------------------
docker restart -t 60 "${fresh}" >/dev/null
wait_api "${fresh}"
check "${fresh}" login
check "${fresh}" has-contact "Restart Contact"
[[ "$(log_count "${fresh}" 'Running Chatwoot first-run setup/update tasks...')" == 1 ]] \
    || fail "first-time setup ran again after the restart" "${fresh}"
[[ "$(log_count "${fresh}" 'Chatwoot is already installed; refreshing application code and running migrations.')" == 1 ]] \
    || fail "the restart did not take the already-installed path" "${fresh}"
pass "restart kept the admin and the contact without running setup again"

# --- moduser.sh ------------------------------------------------------------------
docker exec "${fresh}" /moduser.sh "${NEW_PASSWORD}" >/dev/null || fail "moduser.sh failed" "${fresh}"
check "${fresh}" bad-login
original_password=${PASSWORD}
PASSWORD=${NEW_PASSWORD}
check "${fresh}" login
PASSWORD=${original_password}
no_credentials_logged "${fresh}"
pass "moduser.sh reset the admin password"

# --- update from the previous image ----------------------------------------------
if [[ -n "${previous}" ]]; then
    # The previous image blocks startup on `until curl .../apps/installed/...`.
    # Answer that loop the way the API answers a first install; every other
    # curl call goes to the real curl.
    stub="${scratch}/curl"
    cat >"${stub}" <<'EOF'
#!/bin/sh
for arg in "$@"; do
    case "${arg}" in
        */v1/apps/installed/*) echo 'HTTP/1.1 200 OK'; exit 0 ;;
    esac
done
exec /usr/bin/curl "$@"
EOF
    chmod 755 "${stub}"

    update="${run_id}-update"
    new_volume "${update}"
    start "${update}-old" "${previous}" "${update}" -v "${stub}:/usr/local/bin/curl:ro"
    wait_api "${update}-old"
    old_version=$(check "${update}-old" version)
    check "${update}-old" login
    check "${update}-old" create-contact "Update Contact"
    old_schema=$(schema_version "${update}-old")
    docker stop -t 60 "${update}-old" >/dev/null
    docker rm "${update}-old" >/dev/null

    start "${update}-new" "${image}" "${update}"
    wait_api "${update}-new"
    got_version=$(check "${update}-new" version)
    [[ "${got_version}" == "${want_version}" ]] || fail "after the update /api reports ${got_version}" "${update}-new"
    new_schema=$(schema_version "${update}-new")
    [[ "${new_schema}" > "${old_schema}" ]] || fail "schema ${new_schema} after the update, ${old_schema} before" "${update}-new"
    check "${update}-new" login
    check "${update}-new" has-contact "Update Contact"
    check "${update}-new" signups-closed
    no_credentials_logged "${update}-new"
    pass "update from ${old_version} kept the admin and the contact (schema ${old_schema} -> ${new_schema})"
fi

echo "smoke test passed for ${image}"
