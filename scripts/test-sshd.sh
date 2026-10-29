#!/usr/bin/env bash
# Starts a throwaway sshd on 127.0.0.1:52222 for the SSH tunnel tests, with its own host key, a client key and a
# known_hosts file in one directory (default /tmp/tabula-sshd). Nothing of the user's ~/.ssh is used or changed.
#
#   scripts/test-sshd.sh start          then
#   TABULA_TEST_SSH_DIR=/tmp/tabula-sshd TABULA_TEST_PG_PORT=55432 swift test --filter SSHTunnelTests
#   scripts/test-sshd.sh stop
#
# The tunnels reach the tabula-test-pg container from the README on port 55432.
set -euo pipefail

DIR="${TABULA_TEST_SSH_DIR:-/tmp/tabula-sshd}"
PORT=52222

start() {
  if [ -f "$DIR/sshd.pid" ] && kill -0 "$(cat "$DIR/sshd.pid")" 2>/dev/null; then
    echo "Already running (pid $(cat "$DIR/sshd.pid")); TABULA_TEST_SSH_DIR=$DIR"
    return
  fi
  rm -rf "$DIR"
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  ssh-keygen -q -t ed25519 -N "" -f "$DIR/host_key"
  ssh-keygen -q -t ed25519 -N "" -f "$DIR/client_key"
  cp "$DIR/client_key.pub" "$DIR/authorized_keys"
  chmod 600 "$DIR/authorized_keys"
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$DIR/host_key.pub")" > "$DIR/known_hosts"
  cat > "$DIR/sshd_config" <<CONFIG
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_key
AuthorizedKeysFile $DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PidFile $DIR/sshd.pid
AllowTcpForwarding yes
StrictModes no
CONFIG
  /usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"
  # sshd writes its pid once it listens.
  for _ in $(seq 1 50); do
    [ -f "$DIR/sshd.pid" ] && break
    sleep 0.1
  done
  ssh -i "$DIR/client_key" -o UserKnownHostsFile="$DIR/known_hosts" -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -p "$PORT" 127.0.0.1 true
  echo "Running (pid $(cat "$DIR/sshd.pid")); TABULA_TEST_SSH_DIR=$DIR"
}

stop() {
  if [ -f "$DIR/sshd.pid" ]; then
    kill "$(cat "$DIR/sshd.pid")" 2>/dev/null || true
  fi
  rm -rf "$DIR"
  echo "Stopped"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
