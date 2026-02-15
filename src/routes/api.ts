import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { createAccessMiddleware } from '../auth';
import {
  ensureMoltbotGateway,
  findExistingMoltbotProcessWithRetry,
  syncToR2,
  waitForProcess,
} from '../gateway';

// CLI commands can take 10-15 seconds due to WebSocket overhead.
// Keep generous headroom for cold starts/network jitter during pairing operations.
const CLI_TIMEOUT_MS = 45000;
const LAST_SYNC_FILE = '/tmp/.last-sync';
const LAST_SYNC_ERROR_FILE = '/tmp/.last-sync-error';
const RESTORE_STATUS_FILE = '/tmp/.restore-status.json';
const FORCE_RESTORE_MARKER_FILE = '/tmp/.force-r2-restore';

interface RestoreStatus {
  state: string;
  timestamp: string;
  detail?: string;
}

interface CliOutcome {
  success: boolean;
  status: string;
  stdout: string;
  stderr: string;
  error?: string;
}

function shellEscape(value: string): string {
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function formatCliFailureMessage(
  status: string,
  exitCode: number | undefined,
  stdout: string,
  stderr: string,
): string {
  const trimmedStderr = stderr.trim();
  if (trimmedStderr) return trimmedStderr;

  const trimmedStdout = stdout.trim();
  if (trimmedStdout) return trimmedStdout;

  if (typeof exitCode === 'number') {
    return `Command failed (status=${status}, exitCode=${exitCode})`;
  }

  return `Command failed (status=${status})`;
}

async function evaluateCliOutcome(
  proc: {
    status: string;
    exitCode?: number;
    getStatus?: () => Promise<string>;
    getLogs: () => Promise<{ stdout?: string; stderr?: string }>;
  },
  successKeywords: string[],
): Promise<CliOutcome> {
  const logs = await proc.getLogs();
  const stdout = logs.stdout || '';
  const stderr = logs.stderr || '';
  const status = proc.getStatus ? await proc.getStatus() : proc.status;
  const combinedOutput = `${stdout}\n${stderr}`.toLowerCase();

  const hasKeyword = successKeywords.some((keyword) =>
    combinedOutput.includes(keyword.toLowerCase()),
  );
  const completedWithoutExitCode =
    status === 'completed' && (proc.exitCode === undefined || proc.exitCode === null);
  const success = proc.exitCode === 0 || completedWithoutExitCode || hasKeyword;

  return {
    success,
    status,
    stdout,
    stderr,
    error: success
      ? undefined
      : formatCliFailureMessage(status, proc.exitCode, stdout, stderr),
  };
}

async function readSandboxFile(sandbox: AppEnv['Variables']['sandbox'], path: string): Promise<string> {
  const result = await sandbox.exec(`cat ${path} 2>/dev/null || true`);
  return result.stdout?.trim() || '';
}

function parseRestoreStatus(raw: string): RestoreStatus | null {
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as Partial<RestoreStatus>;
    if (typeof parsed.state !== 'string' || typeof parsed.timestamp !== 'string') {
      return null;
    }
    return {
      state: parsed.state,
      timestamp: parsed.timestamp,
      detail: typeof parsed.detail === 'string' ? parsed.detail : undefined,
    };
  } catch {
    return null;
  }
}

function scheduleBackgroundTask(
  c: { executionCtx?: { waitUntil?: (promise: Promise<unknown>) => unknown } },
  task: Promise<unknown>,
): void {
  let waitUntil: ((promise: Promise<unknown>) => unknown) | undefined;
  try {
    waitUntil = c.executionCtx?.waitUntil;
  } catch {
    waitUntil = undefined;
  }
  if (typeof waitUntil === 'function') {
    waitUntil(task);
    return;
  }

  // Local/test runtimes may not provide waitUntil.
  void task;
}

/**
 * API routes
 * - /api/admin/* - Protected admin API routes (Cloudflare Access required)
 *
 * Note: /api/status is now handled by publicRoutes (no auth required)
 */
const api = new Hono<AppEnv>();

/**
 * Admin API routes - all protected by Cloudflare Access
 */
const adminApi = new Hono<AppEnv>();

// Middleware: Verify Cloudflare Access JWT for all admin routes
adminApi.use('*', createAccessMiddleware({ type: 'json' }));

// GET /api/admin/devices - List pending and paired devices
adminApi.get('/devices', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // Run OpenClaw CLI to list devices
    // Must specify --url and --token (OpenClaw v2026.2.3 requires explicit credentials with --url)
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const proc = await sandbox.startProcess(
      `openclaw devices list --json --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(proc, CLI_TIMEOUT_MS);

    const logs = await proc.getLogs();
    const stdout = logs.stdout || '';
    const stderr = logs.stderr || '';

    // Try to parse JSON output
    try {
      // Find JSON in output (may have other log lines)
      const jsonMatch = stdout.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        const data = JSON.parse(jsonMatch[0]);
        return c.json(data);
      }

      // If no JSON found, return raw output for debugging
      return c.json({
        pending: [],
        paired: [],
        raw: stdout,
        stderr,
      });
    } catch {
      return c.json({
        pending: [],
        paired: [],
        raw: stdout,
        stderr,
        parseError: 'Failed to parse CLI output',
      });
    }
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// POST /api/admin/devices/:requestId/approve - Approve a pending device
adminApi.post('/devices/:requestId/approve', async (c) => {
  const sandbox = c.get('sandbox');
  const requestId = c.req.param('requestId');

  if (!requestId) {
    return c.json({ error: 'requestId is required' }, 400);
  }

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // Run OpenClaw CLI to approve the device
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const escapedRequestId = shellEscape(requestId);
    const proc = await sandbox.startProcess(
      `openclaw devices approve ${escapedRequestId} --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(proc, CLI_TIMEOUT_MS);
    const outcome = await evaluateCliOutcome(proc, ['approved']);

    return c.json({
      success: outcome.success,
      requestId,
      message: outcome.success ? 'Device approved' : 'Approval may have failed',
      stdout: outcome.stdout,
      stderr: outcome.stderr,
      error: outcome.error,
      status: outcome.status,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// POST /api/admin/devices/approve-all - Approve all pending devices
adminApi.post('/devices/approve-all', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Ensure moltbot is running first
    await ensureMoltbotGateway(sandbox, c.env);

    // First, get the list of pending devices
    const token = c.env.MOLTBOT_GATEWAY_TOKEN;
    const tokenArg = token ? ` --token ${token}` : '';
    const listProc = await sandbox.startProcess(
      `openclaw devices list --json --url ws://localhost:18789${tokenArg}`,
    );
    await waitForProcess(listProc, CLI_TIMEOUT_MS);

    const listLogs = await listProc.getLogs();
    const stdout = listLogs.stdout || '';

    // Parse pending devices
    let pending: Array<{ requestId: string }> = [];
    try {
      const jsonMatch = stdout.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        const data = JSON.parse(jsonMatch[0]);
        pending = data.pending || [];
      }
    } catch {
      return c.json({ error: 'Failed to parse device list', raw: stdout }, 500);
    }

    if (pending.length === 0) {
      return c.json({ approved: [], message: 'No pending devices to approve' });
    }

    // Approve each pending device
    const results: Array<{ requestId: string; success: boolean; error?: string }> = [];

    for (const device of pending) {
      try {
        // eslint-disable-next-line no-await-in-loop -- sequential device approval required
        const escapedRequestId = shellEscape(device.requestId);
        const approveProc = await sandbox.startProcess(
          `openclaw devices approve ${escapedRequestId} --url ws://localhost:18789${tokenArg}`,
        );
        // eslint-disable-next-line no-await-in-loop
        await waitForProcess(approveProc, CLI_TIMEOUT_MS);

        // eslint-disable-next-line no-await-in-loop
        const outcome = await evaluateCliOutcome(approveProc, ['approved']);
        results.push({
          requestId: device.requestId,
          success: outcome.success,
          error: outcome.error,
        });
      } catch (err) {
        results.push({
          requestId: device.requestId,
          success: false,
          error: err instanceof Error ? err.message : 'Unknown error',
        });
      }
    }

    const approvedCount = results.filter((r) => r.success).length;
    return c.json({
      approved: results.filter((r) => r.success).map((r) => r.requestId),
      failed: results.filter((r) => !r.success),
      message: `Approved ${approvedCount} of ${pending.length} device(s)`,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// GET /api/admin/storage - Get R2 storage status and last sync time
adminApi.get('/storage', async (c) => {
  const sandbox = c.get('sandbox');
  const hasCredentials = !!(
    c.env.R2_ACCESS_KEY_ID &&
    c.env.R2_SECRET_ACCESS_KEY &&
    c.env.CF_ACCOUNT_ID
  );

  const missing: string[] = [];
  if (!c.env.R2_ACCESS_KEY_ID) missing.push('R2_ACCESS_KEY_ID');
  if (!c.env.R2_SECRET_ACCESS_KEY) missing.push('R2_SECRET_ACCESS_KEY');
  if (!c.env.CF_ACCOUNT_ID) missing.push('CF_ACCOUNT_ID');

  let lastSync: string | null = null;
  let lastSyncError: string | null = null;
  let restore: RestoreStatus | null = null;

  if (hasCredentials) {
    try {
      const [lastSyncRaw, lastSyncErrorRaw, restoreRaw] = await Promise.all([
        readSandboxFile(sandbox, LAST_SYNC_FILE),
        readSandboxFile(sandbox, LAST_SYNC_ERROR_FILE),
        readSandboxFile(sandbox, RESTORE_STATUS_FILE),
      ]);

      const timestamp = lastSyncRaw.trim();
      if (timestamp && timestamp !== '') {
        lastSync = timestamp;
      }

      const syncError = lastSyncErrorRaw.trim();
      if (syncError && syncError !== '') {
        lastSyncError = syncError;
      }

      restore = parseRestoreStatus(restoreRaw);
    } catch {
      // Ignore errors checking sync status
    }
  }

  const backupDegraded = hasCredentials && (lastSyncError !== null || restore?.state === 'failed');

  return c.json({
    configured: hasCredentials,
    missing: missing.length > 0 ? missing : undefined,
    lastSync,
    restore: restore ?? undefined,
    lastSyncError,
    backupDegraded,
    message: hasCredentials
      ? 'R2 storage is configured. Your data will persist across container restarts.'
      : 'R2 storage is not configured. Paired devices and conversations will be lost when the container restarts.',
  });
});

// POST /api/admin/storage/sync - Trigger a manual sync to R2
adminApi.post('/storage/sync', async (c) => {
  const sandbox = c.get('sandbox');

  const result = await syncToR2(sandbox, c.env);

  if (result.success) {
    return c.json({
      success: true,
      message: 'Sync completed successfully',
      lastSync: result.lastSync,
    });
  } else {
    const status = result.error?.includes('not configured') ? 400 : 500;
    return c.json(
      {
        success: false,
        error: result.error,
        details: result.details,
      },
      status,
    );
  }
});

// POST /api/admin/storage/restore - Force full restore from R2 and restart gateway
adminApi.post('/storage/restore', async (c) => {
  const sandbox = c.get('sandbox');

  const hasCredentials = !!(
    c.env.R2_ACCESS_KEY_ID &&
    c.env.R2_SECRET_ACCESS_KEY &&
    c.env.CF_ACCOUNT_ID
  );

  if (!hasCredentials) {
    return c.json(
      {
        success: false,
        error: 'R2 storage is not configured',
      },
      400,
    );
  }

  try {
    await sandbox.exec(`touch ${FORCE_RESTORE_MARKER_FILE}`);

    const existingProcess = await findExistingMoltbotProcessWithRetry(sandbox, c.env);

    if (existingProcess) {
      console.log('Killing existing gateway process for forced restore:', existingProcess.id);
      try {
        await existingProcess.kill();
      } catch (killErr) {
        console.error('Error killing process during forced restore:', killErr);
      }
      await new Promise((r) => setTimeout(r, 2000));
    }

    const bootPromise = ensureMoltbotGateway(sandbox, c.env).catch((err) => {
      console.error('Forced restore restart failed:', err);
    });
    scheduleBackgroundTask(c, bootPromise);

    return c.json({
      success: true,
      message: 'Forced full restore requested. Gateway is restarting with R2 overwrite.',
      previousProcessId: existingProcess?.id,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ success: false, error: errorMessage }, 500);
  }
});

// POST /api/admin/gateway/restart - Kill the current gateway and start a new one
adminApi.post('/gateway/restart', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    // Find and kill the existing gateway process
    const existingProcess = await findExistingMoltbotProcessWithRetry(sandbox, c.env);

    if (existingProcess) {
      console.log('Killing existing gateway process:', existingProcess.id);
      try {
        await existingProcess.kill();
      } catch (killErr) {
        console.error('Error killing process:', killErr);
      }
      // Wait a moment for the process to die
      await new Promise((r) => setTimeout(r, 2000));
    }

    // Start a new gateway in the background
    const bootPromise = ensureMoltbotGateway(sandbox, c.env).catch((err) => {
      console.error('Gateway restart failed:', err);
    });
    scheduleBackgroundTask(c, bootPromise);

    return c.json({
      success: true,
      message: existingProcess
        ? 'Gateway process killed, new instance starting...'
        : 'No existing process found, starting new instance...',
      previousProcessId: existingProcess?.id,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return c.json({ error: errorMessage }, 500);
  }
});

// Mount admin API routes under /admin
api.route('/admin', adminApi);

export { api };
