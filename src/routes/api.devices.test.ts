import { Hono } from 'hono';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AppEnv } from '../types';
import { createMockEnv } from '../test-utils';

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
  waitForProcess: vi.fn().mockResolvedValue('completed'),
}));

import { api } from './api';
import { ensureMoltbotGateway, waitForProcess } from '../gateway';

function createAppWithSandboxStartProcess(
  startProcessImpl: (command: string) => Promise<unknown>,
) {
  const app = new Hono<AppEnv>();
  app.use('*', async (c, next) => {
    c.set(
      'sandbox',
      {
        startProcess: startProcessImpl,
      } as unknown as AppEnv['Variables']['sandbox'],
    );
    await next();
  });
  app.route('/api', api);
  return app;
}

describe('POST /api/admin/devices/:requestId/approve', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(ensureMoltbotGateway).mockResolvedValue({} as never);
    vi.mocked(waitForProcess).mockResolvedValue('completed' as never);
  });

  it('treats completed status without explicit exitCode as success', async () => {
    const process = {
      status: 'completed',
      exitCode: undefined,
      getStatus: vi.fn().mockResolvedValue('completed'),
      getLogs: vi.fn().mockResolvedValue({ stdout: '', stderr: '' }),
    };
    const startProcessMock = vi.fn().mockResolvedValue(process);
    const app = createAppWithSandboxStartProcess(startProcessMock);

    const response = await app.request(
      '/api/admin/devices/req-123/approve',
      { method: 'POST' },
      createMockEnv({ MOLTBOT_GATEWAY_TOKEN: 'test-token' }),
    );
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.success).toBe(true);
    expect(body.requestId).toBe('req-123');
    expect(startProcessMock).toHaveBeenCalledWith(
      expect.stringContaining("openclaw devices approve 'req-123'"),
    );
    expect(startProcessMock).toHaveBeenCalledWith(expect.stringContaining('--token test-token'));
  });

  it('returns CLI stderr when approval fails', async () => {
    const process = {
      status: 'failed',
      exitCode: undefined,
      getStatus: vi.fn().mockResolvedValue('failed'),
      getLogs: vi
        .fn()
        .mockResolvedValue({ stdout: '', stderr: 'pending request not found' }),
    };
    const app = createAppWithSandboxStartProcess(vi.fn().mockResolvedValue(process));

    const response = await app.request(
      '/api/admin/devices/req-404/approve',
      { method: 'POST' },
      createMockEnv({ MOLTBOT_GATEWAY_TOKEN: 'test-token' }),
    );
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.success).toBe(false);
    expect(body.error).toBe('pending request not found');
  });
});
