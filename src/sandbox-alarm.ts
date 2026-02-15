import { Sandbox as CloudflareSandbox } from '@cloudflare/sandbox';

type SandboxAlarmProps = Parameters<CloudflareSandbox['alarm']>[0];

function serializeAlarmError(error: unknown): { message: string; stack?: string } {
  if (error instanceof Error) {
    return { message: error.message, stack: error.stack };
  }

  return { message: String(error) };
}

export class Sandbox extends CloudflareSandbox {
  override async alarm(alarmProps: SandboxAlarmProps): Promise<void> {
    try {
      await super.alarm(alarmProps);
    } catch (error) {
      const metadata = {
        timestamp: new Date().toISOString(),
        retryCount:
          typeof alarmProps.retryCount === 'number' ? alarmProps.retryCount : undefined,
        isRetry: typeof alarmProps.isRetry === 'boolean' ? alarmProps.isRetry : undefined,
      };
      console.error('[SandboxAlarm] alarm loop exception', {
        ...metadata,
        error: serializeAlarmError(error),
      });

      try {
        await this.scheduleNextAlarm(1000);
        console.warn('[SandboxAlarm] scheduled retry after alarm exception', metadata);
      } catch (scheduleError) {
        console.error('[SandboxAlarm] failed to schedule retry alarm', {
          ...metadata,
          error: serializeAlarmError(scheduleError),
        });
      }
    }
  }
}
