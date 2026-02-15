import { getSandbox, type Sandbox, type SandboxOptions } from '@cloudflare/sandbox';
import type { MoltbotEnv } from './types';

const SANDBOX_ID = 'moltbot';
const DEFAULT_RETRY_ATTEMPTS = 3;

const DURABLE_OBJECT_RESET_ERROR_FRAGMENTS = [
  'Internal error in Durable Object storage caused object to be reset',
  'Durable Object reset because its code was updated',
];

export function buildSandboxOptions(env: MoltbotEnv): SandboxOptions {
  const sleepAfter = env.SANDBOX_SLEEP_AFTER?.toLowerCase() || 'never';

  if (sleepAfter === 'never') {
    return { keepAlive: true };
  }

  return { sleepAfter };
}

export function createMoltbotSandbox(env: MoltbotEnv): Sandbox {
  return getSandbox(env.Sandbox, SANDBOX_ID, buildSandboxOptions(env));
}

export function isDurableObjectResetError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  return DURABLE_OBJECT_RESET_ERROR_FRAGMENTS.some((fragment) => error.message.includes(fragment));
}

interface SandboxRetryOptions {
  attempts?: number;
  initialSandbox?: Sandbox;
  operationName?: string;
}

export async function withSandboxResetRetry<T>(
  env: MoltbotEnv,
  operation: (sandbox: Sandbox, attempt: number) => Promise<T>,
  options: SandboxRetryOptions = {},
): Promise<T> {
  const attempts = Math.max(1, options.attempts ?? DEFAULT_RETRY_ATTEMPTS);
  let sandbox = options.initialSandbox ?? createMoltbotSandbox(env);
  let lastError: unknown;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await operation(sandbox, attempt);
    } catch (error) {
      lastError = error;

      if (!isDurableObjectResetError(error) || attempt === attempts) {
        throw error;
      }

      const operationName = options.operationName ?? 'sandbox operation';
      console.warn(
        `[Sandbox] ${operationName} hit Durable Object reset (attempt ${attempt}/${attempts}); recreating sandbox stub and retrying...`,
      );
      sandbox = createMoltbotSandbox(env);
    }
  }

  if (lastError instanceof Error) {
    throw lastError;
  }

  throw new Error('Sandbox operation failed without an error');
}
