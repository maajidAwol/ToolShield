#!/usr/bin/env bash
set -euo pipefail

# SafeArena/WebArena local deployment helper for ToolShield (standalone).
# Downloads + loads the required images if missing, starts the three sites,
# and configures Magento base-URLs. Default is a non-destructive dry run.
#
# Usage:
#   source ~/safearena-env.sh              # point docker at rootless (volume) FIRST
#   bash setup_safearena_local.sh          # dry run: report image/port status
#   bash setup_safearena_local.sh --apply  # download/load if needed, start, configure
#
# Env overrides:
#   SAFEARENA_HOST    host used in base URLs (default: localhost)
#   SAFEARENA_MIRROR  image mirror (default CMU metis)
#   IMAGE_CACHE_DIR   where tars are cached (default /media/volume/comp/safe-arena-images)
#   KEEP_TARS         1=keep tars after load (default), 0=delete to save space
#   FORCE_ROOT_DISK   1=allow loading onto the system Docker on the root disk (danger)

MODE="dry-run"
for arg in "$@"; do
  case "$arg" in
    --apply) MODE="apply" ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SHOPPING_PORT="${SHOPPING_PORT:-7770}"
SHOPPING_ADMIN_PORT="${SHOPPING_ADMIN_PORT:-7780}"
REDDIT_PORT="${REDDIT_PORT:-9999}"
SHOPPING_IMAGE="${SHOPPING_IMAGE:-shopping_final_0712}"
SHOPPING_ADMIN_IMAGE="${SHOPPING_ADMIN_IMAGE:-shopping_admin_final_0719}"
REDDIT_IMAGE="${REDDIT_IMAGE:-postmill-populated-exposed-withimg}"

SAFEARENA_HOST="${SAFEARENA_HOST:-localhost}"
SAFEARENA_MIRROR="${SAFEARENA_MIRROR:-http://metis.lti.cs.cmu.edu/webarena-images}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/media/volume/comp/safe-arena-images}"
KEEP_TARS="${KEEP_TARS:-1}"

echo "SafeArena local setup ($MODE)"
command -v docker >/dev/null || { echo "Docker is required"; exit 1; }

# Which daemon are we talking to? Refuse the root disk unless forced.
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "$DOCKER_ROOT" ]] || { echo "ERROR: cannot reach Docker. Did you 'source ~/safearena-env.sh'?"; exit 1; }
echo "Docker storage: $DOCKER_ROOT"
case "$DOCKER_ROOT" in
  /var/lib/docker*)
    echo "WARNING: this is the SYSTEM Docker on the root disk; the SafeArena images are large."
    echo "         Run 'source ~/safearena-env.sh' to target rootless Docker on the volume."
    [[ "${FORCE_ROOT_DISK:-0}" == "1" ]] || { echo "         Refusing (FORCE_ROOT_DISK=1 to override)."; exit 1; } ;;
esac

for p in "$SHOPPING_PORT" "$SHOPPING_ADMIN_PORT" "$REDDIT_PORT"; do
  if ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]"; then
    echo "ERROR: port $p is already in use"; exit 1
  fi
done

for c in safearena-shopping safearena-shopping-admin safearena-reddit; do
  [[ "$MODE" == "apply" ]] || break
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    echo "ERROR: container $c already exists; remove or rename it first"; exit 1
  fi
done

ensure_image() {
  local image="$1" tar
  tar="$IMAGE_CACHE_DIR/${image}.tar"
  if docker image inspect "$image" >/dev/null 2>&1; then echo "  present: $image"; return 0; fi
  if [[ "$MODE" != "apply" ]]; then
    [[ -f "$tar" ]] && echo "  missing (tar cached, would load): $image" \
                    || echo "  missing (would download + load): $image"
    return 0
  fi
  mkdir -p "$IMAGE_CACHE_DIR"
  if [[ ! -f "$tar" ]]; then
    echo "  downloading $image ..."
    wget -c -O "$tar" "$SAFEARENA_MIRROR/${image}.tar" \
      || { echo "ERROR: download failed: $SAFEARENA_MIRROR/${image}.tar"; exit 1; }
  fi
  echo "  loading $image ..."
  docker load -i "$tar" || { echo "ERROR: docker load failed for $image"; exit 1; }
  [[ "$KEEP_TARS" == "1" ]] || rm -f "$tar"
}

echo "Images:"
if [[ "$MODE" == "apply" ]]; then
  avail=$(df -PBG "$IMAGE_CACHE_DIR" 2>/dev/null | awk 'NR==2{gsub("G","",$4);print $4}')
  [[ -n "${avail:-}" && "$avail" -lt 60 ]] && \
    echo "  WARNING: only ${avail}G free at $IMAGE_CACHE_DIR; images may not fit."
fi
ensure_image "$REDDIT_IMAGE"
ensure_image "$SHOPPING_IMAGE"
ensure_image "$SHOPPING_ADMIN_IMAGE"

cat <<EOF

Planned local services:
  Shopping       http://${SAFEARENA_HOST}:${SHOPPING_PORT}
  Shopping Admin http://${SAFEARENA_HOST}:${SHOPPING_ADMIN_PORT}/admin
  Reddit         http://${SAFEARENA_HOST}:${REDDIT_PORT}

ToolShield MCP ports remain unchanged: 9090, 9091, 9092, 9097.
EOF

if [[ "$MODE" != "apply" ]]; then
  echo "Dry run complete. Re-run with --apply to download/load, start, and configure."
  exit 0
fi

docker run -d --name safearena-shopping      -p "${SHOPPING_PORT}:80"       "$SHOPPING_IMAGE"
docker run -d --name safearena-shopping-admin -p "${SHOPPING_ADMIN_PORT}:80" "$SHOPPING_ADMIN_IMAGE"
docker run -d --name safearena-reddit         -p "${REDDIT_PORT}:80"         "$REDDIT_IMAGE"

configure_magento() {
  local cname="$1" port="$2" ready=0
  echo "Configuring $cname base-url -> http://${SAFEARENA_HOST}:${port} (waiting for Magento) ..."
  for _ in $(seq 1 36); do
    docker exec "$cname" /var/www/magento2/bin/magento --version >/dev/null 2>&1 && { ready=1; break; }
    sleep 5
  done
  [[ "$ready" == "1" ]] || echo "  WARNING: $cname not ready after ~3min; configuring anyway."
  docker exec "$cname" /var/www/magento2/bin/magento setup:store-config:set \
    --base-url="http://${SAFEARENA_HOST}:${port}" || echo "  WARNING: store-config:set failed ($cname)"
  docker exec "$cname" mysql -u magentouser -pMyPassword magentodb -e \
    "UPDATE core_config_data SET value='http://${SAFEARENA_HOST}:${port}/' WHERE path='web/secure/base_url';" \
    || echo "  WARNING: DB base_url update failed ($cname)"
  docker exec "$cname" /var/www/magento2/bin/magento cache:flush || echo "  WARNING: cache:flush failed ($cname)"
}
configure_magento safearena-shopping      "$SHOPPING_PORT"
configure_magento safearena-shopping-admin "$SHOPPING_ADMIN_PORT"

cat <<EOF

Done. Postmill/Reddit needs no extra config. Give the sites ~1 min, then verify:
  curl -sI http://${SAFEARENA_HOST}:${SHOPPING_PORT}            | head -1
  curl -sI http://${SAFEARENA_HOST}:${SHOPPING_ADMIN_PORT}/admin | head -1
  curl -sI http://${SAFEARENA_HOST}:${REDDIT_PORT}             | head -1
EOF
