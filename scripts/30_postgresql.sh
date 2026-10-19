#!/bin/bash
set -eo pipefail
set -x

echo "**************************************************************"
echo "*                    Installing Postgres                     *"
echo "**************************************************************"

if [ ! -f /etc/postgres_installed ]; then
    # Setup postgres Daemon
    echo "Setting up postgres daemon"
    mkdir -p /etc/service/postgres
    cat << EOF > /etc/service/postgres/run
#!/bin/bash
source \${PG_APP_HOME}/functions.sh
[[ \${DEBUG} == true ]] && set -x
# allow arguments to be passed to postgres
if [[ \${1:0:1} = '-' ]]; then
  EXTRA_ARGS="\$@"
  set --
elif [[ \${1} == postgres || \${1} == \$(which postgres) ]]; then
  EXTRA_ARGS="\${@:2}"
  set --
fi
exec start-stop-daemon --start --chuid \${PG_USER}:\${PG_USER} \
--exec \${PG_BINDIR}/postgres -- -D \${PG_DATADIR} \${EXTRA_ARGS}
EOF
    chmod +x /etc/service/postgres/run
    if [ ! -f "${PG_DATADIR}/postgresql.conf" ]; then
        mkdir -p /home/appbox/config/postgresql
        mkdir -p /home/appbox/logs/postgresql

        chown -R appbox:appbox /home/appbox/config/postgresql
        chown -R appbox:appbox /home/appbox/logs/postgresql
        mkdir -p "${PG_RUNDIR:-/run/postgresql}"
        chown -R appbox:appbox "${PG_RUNDIR:-/run/postgresql}"

        source ${PG_APP_HOME}/functions.sh

        stop_postgres_if_running() {
            if [[ -d "${PG_DATADIR}" ]]; then
                sudo -u "${PG_USER}" "${PG_BINDIR}/pg_ctl" -D "${PG_DATADIR}" -m fast -w stop >/dev/null 2>&1 || true
                rm -f "${PG_DATADIR}/postmaster.pid"
            fi
        }
        trap stop_postgres_if_running EXIT

        # default behaviour is to launch postgres
        map_uidgid

        create_datadir
        create_certdir
        create_logdir
        create_rundir

        set_resolvconf_perms

        configure_postgresql

        trap - EXIT
        stop_postgres_if_running
    else
        echo "This is an update, postgres updates should be done from within the app."
    fi
    touch /etc/postgres_installed
else
    echo "Postgres is already installed, just start up."
fi
mkdir -p "${PG_RUNDIR:-/run/postgresql}"
chown -R appbox:appbox "${PG_RUNDIR:-/run/postgresql}"