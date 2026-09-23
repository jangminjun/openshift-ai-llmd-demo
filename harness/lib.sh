HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[llmd-harness]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[llmd-harness:error]\033[0m %s\n' "$*" >&2; exit 1; }

# Execution target for remote/*.sh (HARNESS_EXEC in config.env):
#   bastion -- pipe over SSH to the bastion (original mode)
#   local   -- run on this machine against the current `oc login` session
#   auto    -- local if `oc whoami` succeeds here, bastion otherwise
resolve_exec_mode() {
  case "${HARNESS_EXEC:-auto}" in
    local|bastion) ;;
    auto) if oc whoami >/dev/null 2>&1; then HARNESS_EXEC=local; else HARNESS_EXEC=bastion; fi ;;
    *) err "HARNESS_EXEC must be local|bastion|auto (got: $HARNESS_EXEC)" ;;
  esac
  if [ "$HARNESS_EXEC" = local ]; then
    log "exec=local ($(oc whoami 2>/dev/null)@$(oc whoami --show-server 2>/dev/null))"
  else
    log "exec=bastion (ec2-user@${BASTION_IP})"
  fi
}

ssh_bastion() {
  if [ "${HARNESS_EXEC}" = local ]; then
    bash -c "$*"
  else
    ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
      -i "$SSH_KEY_PATH" "ec2-user@${BASTION_IP}" "$@"
  fi
}

scp_to_bastion() {
  if [ "${HARNESS_EXEC}" = local ]; then
    local dest="${2/#\~/$HOME}"
    mkdir -p "$(dirname "$dest")" && cp "$1" "$dest"
  else
    scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$1" "ec2-user@${BASTION_IP}:$2"
  fi
}

# Prefix for inline `ssh_bastion "..."` commands: installer kubeconfig on the
# bastion, current oc session locally.
KCFG_INIT='[ -f ~/ocp-install/auth/kubeconfig ] && export KUBECONFIG=~/ocp-install/auth/kubeconfig;'
