import { ThrottlerOptions } from '@nestjs/throttler';

/**
 * 名前付き throttler 定義（api-contract-delta.md §0 のレート制限表と一致させる）。
 * 閾値はコード定数（env を増やさない）。
 */
export const THROTTLER_NAME = {
  AUTH_EMAIL: 'auth-email',
  AUTH_USER: 'auth-user',
  RESET_REQUEST: 'reset-request',
  RESET_SUBMIT: 'reset-submit',
  SHARE_WRITE: 'share-write',
} as const;

export type ThrottlerName =
  (typeof THROTTLER_NAME)[keyof typeof THROTTLER_NAME];

/** 全 throttler 名の一覧（SkipThrottle の全消しに使う）。 */
export const ALL_THROTTLER_NAMES: ThrottlerName[] =
  Object.values(THROTTLER_NAME);

const MINUTE_MS = 60_000;

export const THROTTLER_CONFIG: ThrottlerOptions[] = [
  { name: THROTTLER_NAME.AUTH_EMAIL, ttl: 5 * MINUTE_MS, limit: 10 },
  { name: THROTTLER_NAME.AUTH_USER, ttl: 5 * MINUTE_MS, limit: 10 },
  { name: THROTTLER_NAME.RESET_REQUEST, ttl: 15 * MINUTE_MS, limit: 3 },
  { name: THROTTLER_NAME.RESET_SUBMIT, ttl: 15 * MINUTE_MS, limit: 10 },
  { name: THROTTLER_NAME.SHARE_WRITE, ttl: MINUTE_MS, limit: 60 },
];
