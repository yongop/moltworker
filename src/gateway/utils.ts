/**
 * Shared utilities for gateway operations
 */

/**
 * Wait for a sandbox process to complete
 *
 * @param proc - Process object with status and getStatus() method
 * @param timeoutMs - Maximum time to wait in milliseconds
 * @param pollIntervalMs - How often to check status (default 500ms)
 */
export async function waitForProcess(
  proc: { status: string; getStatus?: () => Promise<string> },
  timeoutMs: number,
  pollIntervalMs: number = 500,
): Promise<string> {
  const isInProgress = (status: string): boolean => status === 'running' || status === 'starting';
  const maxAttempts = Math.ceil(timeoutMs / pollIntervalMs);
  let attempts = 0;
  let currentStatus = proc.getStatus ? await proc.getStatus() : proc.status;
  while (isInProgress(currentStatus) && attempts < maxAttempts) {
    // eslint-disable-next-line no-await-in-loop -- intentional sequential polling
    await new Promise((r) => setTimeout(r, pollIntervalMs));
    // proc.status is a snapshot; must call getStatus() to refresh
    currentStatus = proc.getStatus ? await proc.getStatus() : proc.status; // eslint-disable-line no-await-in-loop -- intentional sequential polling
    attempts++;
  }

  if (isInProgress(currentStatus)) {
    throw new Error(
      `Process did not complete within ${timeoutMs}ms (status: ${currentStatus}, attempts: ${attempts})`,
    );
  }

  return currentStatus;
}
