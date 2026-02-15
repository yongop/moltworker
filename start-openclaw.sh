#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (change-detected + 5-minute forced sync)
# 5. Ensures shutdown-time sync before gateway exit
# 6. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"
LAST_SYNC_ERROR_FILE="/tmp/.last-sync-error"
RESTORE_STATUS_FILE="/tmp/.restore-status.json"
RESTORE_ERROR_FILE="/tmp/.restore-error.log"
SYNC_LOG_FILE="/tmp/r2-sync.log"
SYNC_MARKER_FILE="/tmp/.last-sync-marker"
SYNC_LOCK_DIR="/tmp/.r2-sync-lock"
SYNC_SCAN_INTERVAL_SECONDS=30
SYNC_FORCE_INTERVAL_SECONDS=300
AUTH_PROFILES_FILE="$CONFIG_DIR/agents/main/agent/auth-profiles.json"
LEGACY_OAUTH_FILE="$CONFIG_DIR/credentials/oauth.json"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"
touch "$SYNC_LOG_FILE"
rm -f "$RESTORE_ERROR_FILE" "$LAST_SYNC_ERROR_FILE"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_restore_status() {
    local state="$1"
    local detail="${2:-}"
    local timestamp
    timestamp=$(date -Iseconds)

    if [ -n "$detail" ]; then
        printf '{"state":"%s","timestamp":"%s","detail":"%s"}\n' \
            "$state" "$timestamp" "$(json_escape "$detail")" > "$RESTORE_STATUS_FILE"
    else
        printf '{"state":"%s","timestamp":"%s"}\n' \
            "$state" "$timestamp" > "$RESTORE_STATUS_FILE"
    fi
}

record_restore_failure() {
    local detail="$1"
    printf '%s %s\n' "$(date -Iseconds)" "$detail" >> "$RESTORE_ERROR_FILE"
    write_restore_status "failed" "$detail"
}

write_base64_json() {
    local encoded="$1"
    local dest="$2"
    local label="$3"
    local err_file
    err_file=$(mktemp)

    mkdir -p "$(dirname "$dest")"
    if printf '%s' "$encoded" | base64 -d > "$dest" 2>"$err_file"; then
        chmod 600 "$dest"
        rm -f "$err_file"
        echo "Imported $label -> $dest"
    else
        echo "ERROR: Failed to decode $label"
        cat "$err_file" || true
        rm -f "$err_file"
        exit 1
    fi
}

import_oauth_bootstrap() {
    if [ -n "$OPENCLAW_OAUTH_JSON_B64" ]; then
        if [ -f "$LEGACY_OAUTH_FILE" ]; then
            echo "Skipping OPENCLAW_OAUTH_JSON_B64 import (existing file present): $LEGACY_OAUTH_FILE"
        else
            write_base64_json "$OPENCLAW_OAUTH_JSON_B64" "$LEGACY_OAUTH_FILE" "OPENCLAW_OAUTH_JSON_B64"
        fi
    fi
    if [ -n "$OPENCLAW_AUTH_PROFILES_B64" ]; then
        if [ -f "$AUTH_PROFILES_FILE" ]; then
            echo "Skipping OPENCLAW_AUTH_PROFILES_B64 import (existing file present): $AUTH_PROFILES_FILE"
        else
            write_base64_json "$OPENCLAW_AUTH_PROFILES_B64" "$AUTH_PROFILES_FILE" "OPENCLAW_AUTH_PROFILES_B64"
        fi
    fi
}

has_seeded_auth() {
    [ -f "$AUTH_PROFILES_FILE" ] || [ -f "$LEGACY_OAUTH_FILE" ]
}

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"
RCLONE_BASE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"
RCLONE_RETRY_FLAGS="--retries=5 --retries-sleep=10s"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

dir_has_meaningful_files() {
    local dir="$1"
    shift || true

    if [ ! -d "$dir" ]; then
        return 1
    fi

    local found
    found=$(find "$dir" "$@" -type f -print -quit 2>/dev/null || true)
    [ -n "$found" ]
}

local_state_exists() {
    if [ -f "$CONFIG_FILE" ]; then
        return 0
    fi

    if dir_has_meaningful_files "$WORKSPACE_DIR" -not -path '*/node_modules/*' -not -path '*/.git/*'; then
        return 0
    fi

    if dir_has_meaningful_files "$SKILLS_DIR"; then
        return 0
    fi

    return 1
}

probe_r2_entries() {
    local remote="$1"
    local label="$2"
    local max_depth="${3:-1}"
    local output_file
    local error_file
    output_file=$(mktemp)
    error_file=$(mktemp)

    if rclone ls "$remote" $RCLONE_BASE_FLAGS $RCLONE_RETRY_FLAGS --max-depth "$max_depth" >"$output_file" 2>"$error_file"; then
        if [ -s "$output_file" ]; then
            rm -f "$output_file" "$error_file"
            echo "exists"
            return 0
        fi

        rm -f "$output_file" "$error_file"
        echo "missing"
        return 0
    fi

    local detail
    detail=$(tail -n 20 "$error_file" | tr '\n' ' ')
    detail=${detail:-"Unknown R2 probe error"}
    rm -f "$output_file" "$error_file"

    local detail_lower
    detail_lower=$(printf '%s' "$detail" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$detail_lower" | grep -Eq "not found|does not exist|doesn't exist|404|no such file|directory not found|object not found"; then
        echo "missing"
        return 0
    fi

    echo "error:${label} probe failed: $detail"
}

copy_r2_prefix_to_local() {
    local remote="$1"
    local local_dir="$2"
    local label="$3"

    mkdir -p "$local_dir"
    if ! rclone copy "$remote" "${local_dir}/" $RCLONE_BASE_FLAGS $RCLONE_RETRY_FLAGS -v >>"$RESTORE_ERROR_FILE" 2>&1; then
        record_restore_failure "Restore failed for ${label} from ${remote}"
        return 1
    fi

    echo "${label} restored from ${remote}"
    return 0
}

restore_from_r2() {
    if ! r2_configured; then
        echo "R2 not configured, starting fresh"
        write_restore_status "not_configured" "R2 credentials not configured"
        return 0
    fi

    setup_rclone

    if local_state_exists; then
        echo "Local state exists, skipping R2 restore."
        write_restore_status "skipped_local" "Local state exists, skipped remote restore"
        return 0
    fi

    echo "Checking R2 for existing backup..."
    local restored_any=0

    local openclaw_probe
    openclaw_probe=$(probe_r2_entries "r2:${R2_BUCKET}/openclaw/openclaw.json" "openclaw config" 1)
    case "$openclaw_probe" in
        exists)
            copy_r2_prefix_to_local "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR" "Config" || return 1
            restored_any=1
            ;;
        missing)
            local legacy_probe
            legacy_probe=$(probe_r2_entries "r2:${R2_BUCKET}/clawdbot/clawdbot.json" "legacy config" 1)
            case "$legacy_probe" in
                exists)
                    copy_r2_prefix_to_local "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR" "Legacy config" || return 1
                    if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
                        mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
                    fi
                    echo "Legacy config restored and migrated"
                    restored_any=1
                    ;;
                missing)
                    echo "No config backup found in R2"
                    ;;
                error:*)
                    record_restore_failure "$legacy_probe"
                    return 1
                    ;;
            esac
            ;;
        error:*)
            record_restore_failure "$openclaw_probe"
            return 1
            ;;
    esac

    local workspace_probe
    workspace_probe=$(probe_r2_entries "r2:${R2_BUCKET}/workspace/" "workspace" 1)
    case "$workspace_probe" in
        exists)
            copy_r2_prefix_to_local "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR" "Workspace" || return 1
            restored_any=1
            ;;
        missing)
            echo "No workspace backup found in R2"
            ;;
        error:*)
            record_restore_failure "$workspace_probe"
            return 1
            ;;
    esac

    local skills_probe
    skills_probe=$(probe_r2_entries "r2:${R2_BUCKET}/skills/" "skills" 1)
    case "$skills_probe" in
        exists)
            copy_r2_prefix_to_local "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR" "Skills" || return 1
            restored_any=1
            ;;
        missing)
            echo "No skills backup found in R2"
            ;;
        error:*)
            record_restore_failure "$skills_probe"
            return 1
            ;;
    esac

    if [ "$restored_any" -eq 1 ]; then
        write_restore_status "restored" "R2 backup restored into empty local state"
    else
        write_restore_status "fresh" "No R2 backup found"
    fi

    return 0
}

restore_from_r2

# ============================================================
# OAUTH BOOTSTRAP IMPORT
# ============================================================
# Import OpenClaw auth state from secrets when provided.
# This is primarily used for headless Codex OAuth bootstrapping.
import_oauth_bootstrap

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    elif has_seeded_auth; then
        AUTH_ARGS="--auth-choice skip"
    else
        AUTH_ARGS="--auth-choice skip"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
const authProfilesPath = '/root/.openclaw/agents/main/agent/auth-profiles.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

function normalizeProviderId(value) {
    return String(value || '').trim().toLowerCase();
}

function getCodexProfileIdsFromStore(path) {
    try {
        const raw = fs.readFileSync(path, 'utf8');
        const parsed = JSON.parse(raw);
        const profiles = parsed && typeof parsed === 'object' ? parsed.profiles : undefined;
        if (!profiles || typeof profiles !== 'object') {
            return [];
        }
        return Object.entries(profiles)
            .filter(([, cred]) => normalizeProviderId(cred && cred.provider) === 'openai-codex')
            .map(([id]) => id);
    } catch (err) {
        console.warn('Could not read auth-profiles.json for reconciliation:', err && err.message ? err.message : String(err));
        return [];
    }
}

function reconcileCodexAuthConfig(configObj, codexProfileIds) {
    if (!Array.isArray(codexProfileIds) || codexProfileIds.length === 0) {
        return false;
    }

    configObj.auth = configObj.auth || {};

    const existingProfiles =
        configObj.auth.profiles && typeof configObj.auth.profiles === 'object'
            ? { ...configObj.auth.profiles }
            : {};
    let changed = false;

    for (const [profileId, profile] of Object.entries(existingProfiles)) {
        if (normalizeProviderId(profile && profile.provider) !== 'openai-codex') {
            continue;
        }
        if (!codexProfileIds.includes(profileId)) {
            delete existingProfiles[profileId];
            changed = true;
        }
    }

    const codexProfilesInConfig = Object.entries(existingProfiles)
        .filter(([, profile]) => normalizeProviderId(profile && profile.provider) === 'openai-codex')
        .map(([profileId]) => profileId);

    if (codexProfilesInConfig.length === 0) {
        for (const profileId of codexProfileIds) {
            existingProfiles[profileId] = { provider: 'openai-codex', mode: 'oauth' };
        }
        changed = true;
    }

    const existingOrder =
        configObj.auth.order && typeof configObj.auth.order === 'object'
            ? { ...configObj.auth.order }
            : {};
    const dedupedCodexIds = Array.from(new Set(codexProfileIds));
    let foundCodexOrderKey = false;

    for (const [providerKey, value] of Object.entries(existingOrder)) {
        if (normalizeProviderId(providerKey) !== 'openai-codex') {
            continue;
        }
        foundCodexOrderKey = true;
        const currentList = Array.isArray(value) ? value : [];
        const filtered = currentList.filter((profileId) => dedupedCodexIds.includes(profileId));
        const nextList = filtered.length > 0 ? Array.from(new Set(filtered)) : dedupedCodexIds;

        if (JSON.stringify(currentList) !== JSON.stringify(nextList)) {
            existingOrder[providerKey] = nextList;
            changed = true;
        }
    }

    if (!foundCodexOrderKey) {
        existingOrder['openai-codex'] = dedupedCodexIds;
        changed = true;
    }

    configObj.auth.profiles = existingProfiles;
    configObj.auth.order = existingOrder;
    return changed;
}

const codexProfileIds = getCodexProfileIdsFromStore(authProfilesPath);
if (codexProfileIds.length > 0) {
    const updated = reconcileCodexAuthConfig(config, codexProfileIds);
    if (updated) {
        console.log('Reconciled openai-codex auth config with auth-profiles.json:', codexProfileIds.join(', '));
    }
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Break-glass mode for stuck device-token states:
// disable strict device-token checks in the Control UI.
if (process.env.OPENCLAW_DISABLE_DEVICE_AUTH === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
    config.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
    console.warn('WARNING: OPENCLAW_DISABLE_DEVICE_AUTH=true (device auth disabled for Control UI)');
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Default model override (useful for Codex OAuth bootstrap).
if (process.env.OPENCLAW_DEFAULT_MODEL) {
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: process.env.OPENCLAW_DEFAULT_MODEL };
    console.log('Default model override:', process.env.OPENCLAW_DEFAULT_MODEL);
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

sync_once() {
    local reason="${1:-manual}"

    if ! r2_configured; then
        return 0
    fi

    if ! mkdir "$SYNC_LOCK_DIR" 2>/dev/null; then
        echo "[sync] Skip (lock busy) reason=${reason} at $(date -Iseconds)" >> "$SYNC_LOG_FILE"
        return 0
    fi

    local sync_ok=1
    local error_file
    error_file=$(mktemp)

    echo "[sync] Start reason=${reason} at $(date -Iseconds)" >> "$SYNC_LOG_FILE"

    if ! rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
        $RCLONE_BASE_FLAGS $RCLONE_RETRY_FLAGS \
        --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' >>"$SYNC_LOG_FILE" 2>>"$error_file"; then
        sync_ok=0
    fi

    if [ -d "$WORKSPACE_DIR" ]; then
        if ! rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
            $RCLONE_BASE_FLAGS $RCLONE_RETRY_FLAGS \
            --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' >>"$SYNC_LOG_FILE" 2>>"$error_file"; then
            sync_ok=0
        fi
    fi

    if [ -d "$SKILLS_DIR" ]; then
        if ! rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
            $RCLONE_BASE_FLAGS $RCLONE_RETRY_FLAGS >>"$SYNC_LOG_FILE" 2>>"$error_file"; then
            sync_ok=0
        fi
    fi

    if [ "$sync_ok" -eq 1 ]; then
        date -Iseconds > "$LAST_SYNC_FILE"
        rm -f "$LAST_SYNC_ERROR_FILE"
        touch "$SYNC_MARKER_FILE"
        echo "[sync] Complete reason=${reason} at $(date -Iseconds)" >> "$SYNC_LOG_FILE"
    else
        local error_tail
        error_tail=$(tail -n 50 "$error_file" | tr '\n' ' ')
        error_tail=${error_tail:-"Unknown sync failure"}
        printf '%s\n' "$(date -Iseconds) reason=${reason} ${error_tail}" > "$LAST_SYNC_ERROR_FILE"
        echo "[sync] Failed reason=${reason} at $(date -Iseconds)" >> "$SYNC_LOG_FILE"
    fi

    rm -f "$error_file"
    rmdir "$SYNC_LOCK_DIR" 2>/dev/null || true

    if [ "$sync_ok" -eq 1 ]; then
        return 0
    fi

    return 1
}

SYNC_LOOP_PID=""
GATEWAY_PID=""
SHUTTING_DOWN=0

start_sync_loop() {
    if ! r2_configured; then
        return 0
    fi

    echo "Starting background R2 sync loop..."
    (
        touch "$SYNC_MARKER_FILE"
        last_forced_sync_epoch=$(date +%s)

        while true; do
            sleep "$SYNC_SCAN_INTERVAL_SECONDS"

            changed_file=$(
                {
                    find "$CONFIG_DIR" -newer "$SYNC_MARKER_FILE" -type f -printf '%P\n' 2>/dev/null
                    find "$WORKSPACE_DIR" -newer "$SYNC_MARKER_FILE" \
                        -not -path '*/node_modules/*' \
                        -not -path '*/.git/*' \
                        -type f -printf '%P\n' 2>/dev/null
                    find "$SKILLS_DIR" -newer "$SYNC_MARKER_FILE" -type f -printf '%P\n' 2>/dev/null
                } | head -n 1
            )

            now_epoch=$(date +%s)
            force_due=0
            if [ $((now_epoch - last_forced_sync_epoch)) -ge "$SYNC_FORCE_INTERVAL_SECONDS" ]; then
                force_due=1
            fi

            if [ -n "$changed_file" ] || [ "$force_due" -eq 1 ]; then
                reason="change-detected"
                if [ -n "$changed_file" ] && [ "$force_due" -eq 1 ]; then
                    reason="change+periodic-5m"
                elif [ "$force_due" -eq 1 ]; then
                    reason="periodic-5m"
                fi

                if sync_once "$reason"; then
                    last_forced_sync_epoch="$now_epoch"
                fi
            fi
        done
    ) &
    SYNC_LOOP_PID=$!
    echo "Background sync loop started (PID: ${SYNC_LOOP_PID})"
}

stop_sync_loop() {
    if [ -n "$SYNC_LOOP_PID" ] && kill -0 "$SYNC_LOOP_PID" 2>/dev/null; then
        kill -TERM "$SYNC_LOOP_PID" 2>/dev/null || true
        wait "$SYNC_LOOP_PID" 2>/dev/null || true
    fi
    SYNC_LOOP_PID=""
}

run_shutdown_sync_with_timeout() {
    local timeout_seconds=45
    sync_once "shutdown" &
    local sync_pid=$!
    local waited=0

    while kill -0 "$sync_pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout_seconds" ]; then
            echo "[shutdown] Shutdown sync timed out after ${timeout_seconds}s" >> "$SYNC_LOG_FILE"
            kill -TERM "$sync_pid" 2>/dev/null || true
            wait "$sync_pid" 2>/dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    wait "$sync_pid"
}

shutdown_handler() {
    if [ "$SHUTTING_DOWN" -eq 1 ]; then
        return
    fi
    SHUTTING_DOWN=1

    echo "[shutdown] Signal received at $(date -Iseconds)"

    if r2_configured; then
        run_shutdown_sync_with_timeout || true
    fi

    stop_sync_loop

    if [ -n "$GATEWAY_PID" ] && kill -0 "$GATEWAY_PID" 2>/dev/null; then
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
        wait "$GATEWAY_PID" 2>/dev/null || true
    fi

    exit 0
}

trap shutdown_handler TERM INT

start_sync_loop

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN" &
else
    echo "Starting gateway with device pairing (no token)..."
    openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan &
fi

GATEWAY_PID=$!
set +e
wait "$GATEWAY_PID"
gateway_exit=$?
set -e

stop_sync_loop
exit "$gateway_exit"
