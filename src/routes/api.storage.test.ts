import { Hono } from 'hono';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AppEnv } from '../types';
import { createMockEnv, createMockEnvWithR2, createMockExecResult } from '../test-utils';

vi.mock('../auth', () => ({
  createAccessMiddleware:
    () =>
    async (_c: unknown, next: () => Promise<void>): Promise<void> =>
      next(),
}));

vi.mock('../gateway', () => ({
  ensureMoltbotGateway: vi.fn().mockResolvedValue({}),
  findExistingMoltbotProcessWithRetry: vi.fn(),
  syncToR2: vi.fn(),
  waitForProcess: vi.fn(),
}));

import { api } from './api';
import { ensureMoltbotGateway, findExistingMoltbotProcessWithRetry } from '../gateway';

function createAppWithSandboxExec(execImpl: (command: string) => Promise<ReturnType<typeof createMockExecResult>>) {
  const app = new Hono<AppEnv>();
  app.use('*', async (c, next) => {
    c.set(
      'sandbox',
      {
        exec: execImpl,
      } as unknown as AppEnv['Variables']['sandbox'],
    );
    await next();
  });
  app.route('/api', api);
  return app;
}

describe('GET /api/admin/storage', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(ensureMoltbotGateway).mockResolvedValue({} as never);
    vi.mocked(findExistingMoltbotProcessWithRetry).mockResolvedValue(null);
  });

  it('parses restore status when restore metadata exists', async () => {
    const app = createAppWithSandboxExec(async (command) => {
      if (command.includes('/tmp/.last-sync ')) {
        return createMockExecResult('2026-02-15T12:30:00+00:00');
      }
      if (command.includes('/tmp/.last-sync-error ')) {
        return createMockExecResult('');
      }
      if (command.includes('/tmp/.restore-status.json ')) {
        return createMockExecResult(
          '{"state":"restored","timestamp":"2026-02-15T12:20:00+00:00","detail":"R2 backup restored"}',
        );
      }
      return createMockExecResult('');
    });

    const response = await app.request('/api/admin/storage', {}, createMockEnvWithR2());
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.configured).toBe(true);
    expect(body.lastSync).toBe('2026-02-15T12:30:00+00:00');
    expect(body.restore).toEqual({
      state: 'restored',
      timestamp: '2026-02-15T12:20:00+00:00',
      detail: 'R2 backup restored',
    });
    expect(body.backupDegraded).toBe(false);
  });

  it('reports degraded backup state when restore status is failed', async () => {
    const app = createAppWithSandboxExec(async (command) => {
      if (command.includes('/tmp/.restore-status.json ')) {
        return createMockExecResult(
          '{"state":"failed","timestamp":"2026-02-15T12:25:00+00:00","detail":"R2 probe failed"}',
        );
      }
      return createMockExecResult('');
    });

    const response = await app.request('/api/admin/storage', {}, createMockEnvWithR2());
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.restore).toEqual({
      state: 'failed',
      timestamp: '2026-02-15T12:25:00+00:00',
      detail: 'R2 probe failed',
    });
    expect(body.backupDegraded).toBe(true);
  });

  it('reports last sync error and degraded state when sync is failing', async () => {
    const app = createAppWithSandboxExec(async (command) => {
      if (command.includes('/tmp/.last-sync-error ')) {
        return createMockExecResult('2026-02-15T12:31:00+00:00 reason=periodic-5m rclone timeout');
      }
      return createMockExecResult('');
    });

    const response = await app.request('/api/admin/storage', {}, createMockEnvWithR2());
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.lastSyncError).toContain('rclone timeout');
    expect(body.backupDegraded).toBe(true);
  });

  it('keeps compatibility for unconfigured R2 responses', async () => {
    const app = createAppWithSandboxExec(async () => createMockExecResult(''));
    const response = await app.request('/api/admin/storage', {}, createMockEnv());
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.configured).toBe(false);
    expect(body.lastSync).toBeNull();
    expect(body.lastSyncError).toBeNull();
    expect(body.backupDegraded).toBe(false);
  });

  it('triggers forced restore and restart when R2 is configured', async () => {
    const execMock = vi.fn(async () => createMockExecResult(''));
    const killMock = vi.fn().mockResolvedValue(undefined);
    vi.mocked(findExistingMoltbotProcessWithRetry).mockResolvedValue({
      id: 'proc-1',
      kill: killMock,
    } as never);

    const app = createAppWithSandboxExec(execMock);
    const response = await app.request(
      '/api/admin/storage/restore',
      { method: 'POST' },
      createMockEnvWithR2(),
    );
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.success).toBe(true);
    expect(execMock).toHaveBeenCalledWith(expect.stringContaining('/tmp/.force-r2-restore'));
    expect(killMock).toHaveBeenCalledTimes(1);
    expect(ensureMoltbotGateway).toHaveBeenCalledTimes(1);
  });

  it('rejects forced restore when R2 is not configured', async () => {
    const app = createAppWithSandboxExec(async () => createMockExecResult(''));
    const response = await app.request(
      '/api/admin/storage/restore',
      { method: 'POST' },
      createMockEnv(),
    );
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(400);
    expect(body.success).toBe(false);
    expect(body.error).toBe('R2 storage is not configured');
  });
});
