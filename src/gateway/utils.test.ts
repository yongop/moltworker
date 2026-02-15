import { describe, expect, it, vi } from 'vitest';
import { waitForProcess } from './utils';

describe('waitForProcess', () => {
  it('returns final status when process completes before timeout', async () => {
    const statuses = ['running', 'running', 'completed'];
    const proc = {
      status: 'running',
      getStatus: vi.fn(async () => statuses.shift() ?? 'completed'),
    };

    await expect(waitForProcess(proc, 25, 1)).resolves.toBe('completed');
    expect(proc.getStatus).toHaveBeenCalled();
  });

  it('throws when process is still running at timeout', async () => {
    const proc = {
      status: 'running',
      getStatus: vi.fn(async () => 'running'),
    };

    await expect(waitForProcess(proc, 5, 1)).rejects.toThrow('Process did not complete within');
  });
});
