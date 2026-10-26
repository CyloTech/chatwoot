#!/bin/bash
set -euo pipefail

NEW_PASSWORD="${1:-}"

if [[ -z "${NEW_PASSWORD}" ]]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

if [[ ! -f /etc/profile.d/chatwoot-runtime.sh ]]; then
    echo "Chatwoot runtime environment not found."
    exit 1
fi

# RVM is loaded only in the appbox shell below. It reads variables it never
# sets and replaces cd with a function that does the same, so neither can run
# in this set -u shell.
cat > /tmp/chatwoot_moduser.rb <<'RUBY'
user = User.joins(:account_users).merge(AccountUser.where(role: :administrator)).first || User.first
raise "No Chatwoot users found" unless user

password = ENV.fetch("NEW_PASSWORD")
user.password = password
user.password_confirmation = password
user.save!

puts "Password reset for #{user.email}"
RUBY

sudo -u appbox env NEW_PASSWORD="${NEW_PASSWORD}" bash -lc '
source /usr/share/rvm/scripts/rvm
source /etc/profile.d/chatwoot-runtime.sh
cd /home/appbox/chatwoot
bundle exec rails runner /tmp/chatwoot_moduser.rb
'

rm -f /tmp/chatwoot_moduser.rb
