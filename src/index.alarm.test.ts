import { beforeEach, describe, expect, it, vi } from 'vitest';

const superAlarmMock = vi.fn();
const scheduleNextAlarmMock = vi.fn();

class MockCloudflareSandbox {
  async alarm(...args: unknown[]) {
    return superAlarmMock(...args);
  }

  async scheduleNextAlarm(...args: unknown[]) {
    return scheduleNextAlarmMock(...args);
  }
}

vi.mock('@cloudflare/sandbox', () => ({
  Sandbox: MockCloudflareSandbox,
  getSandbox: vi.fn(),
}));

describe('Sandbox alarm guard', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
  });

  it('swallows alarm exceptions and schedules a retry', async () => {
    superAlarmMock.mockRejectedValueOnce(new Error('alarm failed'));
    scheduleNextAlarmMock.mockResolvedValueOnce(undefined);

    const { Sandbox } = await import('./sandbox-alarm');
    const sandbox = new Sandbox({} as never, {} as never);

    await expect(sandbox.alarm({ isRetry: false, retryCount: 0 } as never)).resolves.toBeUndefined();
    expect(scheduleNextAlarmMock).toHaveBeenCalledWith(1000);
  });

  it('does not schedule retry when alarm succeeds', async () => {
    superAlarmMock.mockResolvedValueOnce(undefined);

    const { Sandbox } = await import('./sandbox-alarm');
    const sandbox = new Sandbox({} as never, {} as never);

    await expect(sandbox.alarm({ isRetry: false, retryCount: 0 } as never)).resolves.toBeUndefined();
    expect(scheduleNextAlarmMock).not.toHaveBeenCalled();
  });
});
