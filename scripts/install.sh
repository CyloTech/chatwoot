#!/bin/bash
set -eo pipefail

\. "${NVM_DIR}/nvm.sh" && \
nvm use "${NODE_VERSION}" && \
npm install -g "pnpm@${PNPM_VERSION}" && \
export USER="${USER:-appbox}" && \
source "/usr/share/rvm/scripts/rvm" && \
git clone https://github.com/chatwoot/chatwoot.git /chatwoot && \
cd chatwoot && \
git checkout tags/v${CHATWOOT_VER} && \
pnpm install --frozen-lockfile && \
bundle config set without 'development test'; bundle install -j 4 -r 3 && \
SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled NODE_OPTIONS="${NODE_OPTIONS}" bundle exec rake assets:precompile && \
rm -rf spec node_modules tmp/cache