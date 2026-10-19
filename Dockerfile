# Chatwoot for Appbox
FROM phusion/baseimage:jammy-1.0.4

ENV PG_VERSION=16 \
    PG_HOME=/home/appbox/config/postgresql \
    RUBY_VERSION=3.4.4 \
    NODE_VERSION=24.13.0 \
    PNPM_VERSION=10.2.0

ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT ${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.5.16

ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES ${RAILS_SERVE_STATIC_FILES}

ARG RAILS_ENV=production
ENV RAILS_ENV ${RAILS_ENV}

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/appbox \
    USER=appbox \
    NVM_DIR=/.nvm \
    PG_APP_HOME="/etc/docker-postgresql" \
    PG_USER=appbox \
    PG_RUNDIR=/run/postgresql \
    PG_LOGDIR=/home/appbox/logs/postgresql \
    PG_CERTDIR=/etc/postgresql/certs \
    DB_USER=chatwoot \
    DB_PASS=chatwoot \
    DB_NAME=chatwoot_production \
    PG_BINDIR=/usr/lib/postgresql/${PG_VERSION}/bin \
    PG_DATADIR=${PG_HOME}/${PG_VERSION}/main \
    PORT=3000 \
    RAILS_ENV=production \
    NODE_ENV=production \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true \
    NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider" \
    GEM_HOME=/usr/share/rvm/gems/ruby-${RUBY_VERSION} \
    GEM_PATH=/usr/share/rvm/gems/ruby-${RUBY_VERSION}:/usr/share/rvm/gems/ruby-${RUBY_VERSION}@global \
    CHATWOOT_VER=4.14.2

RUN apt update && \
    apt install -y --no-install-recommends sudo wget curl git software-properties-common jq bsdmainutils ca-certificates gnupg && \
    apt-add-repository -y ppa:rael-gc/rvm && \
    apt-get update && \
    apt-get install -y --no-install-recommends rvm

RUN bash -c 'source "/usr/share/rvm/scripts/rvm" && \
    rvm install ruby-${RUBY_VERSION} && \
    rvm alias create default ruby-${RUBY_VERSION} && \
    gem install bundler -v "${BUNDLER_VERSION}"'

RUN mkdir -p "${NVM_DIR}" && \
    HOME=/ curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && \
    \. "${NVM_DIR}/nvm.sh" && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    nvm use ${NODE_VERSION} && \
    node -v && \
    nvm current && \
    npm -v
    

RUN \. "${NVM_DIR}/nvm.sh" && \
    nvm use ${NODE_VERSION} && \
    npm install -g pnpm@${PNPM_VERSION} && \
    pnpm --version

RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo 'deb http://apt.postgresql.org/pub/repos/apt/ jammy-pgdg main' >> /etc/apt/sources.list && \
    apt update && \
    apt install -y --no-install-recommends postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} postgresql-contrib-${PG_VERSION} postgresql-${PG_VERSION}-pgvector && \
    ln -sf ${PG_DATADIR}/postgresql.conf /etc/postgresql/${PG_VERSION}/main/postgresql.conf && \
    ln -sf ${PG_DATADIR}/pg_hba.conf /etc/postgresql/${PG_VERSION}/main/pg_hba.conf && \
    ln -sf ${PG_DATADIR}/pg_ident.conf /etc/postgresql/${PG_VERSION}/main/pg_ident.conf && \
    rm -rf ${PG_HOME} && \
    mkdir -p ${PG_APP_HOME}

RUN curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg && \
    chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list && \
    apt update && \
    apt -y install --no-install-recommends build-essential libpq-dev libvips redis-server imagemagick redis-tools

RUN adduser --system --disabled-password --home /home/appbox --shell /sbin/nologin --group --uid 1000 appbox && \
    usermod -a -G rvm appbox && \
    chown -R appbox:appbox /home/appbox

COPY scripts/install.sh /scripts/install.sh
RUN chmod +x /scripts/install.sh && \
    /scripts/install.sh && \
    rm -f /scripts/install.sh

COPY scripts/postgres/ ${PG_APP_HOME}/
COPY scripts/ /scripts/
RUN rm -f /scripts/install.sh && \
    find /scripts/ -name '*.sh' -exec chmod a+x {} +
COPY ./moduser.sh /moduser.sh
RUN chmod +x /moduser.sh

RUN groupmod -g 9999 nogroup && \
    usermod -g 9999 nobody && \
    usermod -u 9999 nobody && \
    usermod -g 9999 sync && \
    usermod -g 9999 _apt

RUN mkdir -p /etc/my_init.d
RUN mv /scripts/20_installer.sh /etc/my_init.d/20_installer.sh
RUN chmod -R +x /etc/my_init.d/20_installer.sh

EXPOSE 3000

# Clean up APT when done.
RUN apt autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Use baseimage-docker's init system.
CMD ["/sbin/my_init"]