import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

/** free プランの名義上限（bonus 加算前）。 */
export const FREE_IDENTITY_LIMIT = 10;
/** free プランの同時有効共有リンク数。 */
export const FREE_SHARE_LIMIT = 1;
/** free プランの write 共有 1 本あたりの公演数上限（C8）。 */
export const FREE_SHARE_WRITE_EVENT_LIMIT = 3;

export type Plan = 'free' | 'plus';

export interface EntitlementView {
  plan: Plan;
  expiresAt: Date | null;
  inGracePeriod: boolean;
  bonusIdentitySlots: number;
  bonusExpiresAt: Date | null;
}

const DEFAULT_ENTITLEMENT: EntitlementView = {
  plan: 'free',
  expiresAt: null,
  inGracePeriod: false,
  bonusIdentitySlots: 0,
  bonusExpiresAt: null,
};

/**
 * entitlements は RevenueCat Webhook (billing) だけが書き込む（ADR-002）。
 * 本サービスは読み取りと導出のみを提供し、書き込みメソッドを持たない。
 */
@Injectable()
export class EntitlementsService {
  constructor(private readonly prisma: PrismaService) {}

  async get(userId: string): Promise<EntitlementView> {
    const row = await this.prisma.entitlement.findUnique({
      where: { userId },
    });
    // 行が無いユーザーは free 既定として扱う（E-5）
    if (!row) return { ...DEFAULT_ENTITLEMENT };
    return {
      plan: row.plan === 'plus' ? 'plus' : 'free',
      expiresAt: row.expiresAt,
      inGracePeriod: row.inGracePeriod,
      bonusIdentitySlots: row.bonusIdentitySlots,
      bonusExpiresAt: row.bonusExpiresAt,
    };
  }

  /** 名義の作成上限。null は無制限。 */
  async identityLimit(userId: string): Promise<number | null> {
    const entitlement = await this.get(userId);
    if (isUnlimited(entitlement)) return null;
    return FREE_IDENTITY_LIMIT + activeBonusSlots(entitlement);
  }

  /** 同時に有効化できる共有リンク数。null は無制限。 */
  async shareLimit(userId: string): Promise<number | null> {
    const entitlement = await this.get(userId);
    if (isUnlimited(entitlement)) return null;
    return FREE_SHARE_LIMIT;
  }

  /** write 共有リンク 1 本に含められる公演（event）数の上限。null は無制限（FR-SW-3）。 */
  async shareWriteEventLimit(userId: string): Promise<number | null> {
    const entitlement = await this.get(userId);
    if (isUnlimited(entitlement)) return null;
    return FREE_SHARE_WRITE_EVENT_LIMIT;
  }
}

/**
 * **plus** が有効（未失効）、または **plus** の猶予期間中なら無制限（FR-ID-4）。
 * `in_grace_period` は plan 判定より後に見る。free 行に立っていても上限は外れない。
 */
function isUnlimited(entitlement: EntitlementView): boolean {
  if (entitlement.plan !== 'plus') return false;
  if (entitlement.inGracePeriod) return true;
  return (
    entitlement.expiresAt === null ||
    entitlement.expiresAt.getTime() > Date.now()
  );
}

/** bonus_expires_at が未来のときだけ bonus 枠を加算する（期限ちょうどは無効）。 */
function activeBonusSlots(entitlement: EntitlementView): number {
  const { bonusExpiresAt, bonusIdentitySlots } = entitlement;
  if (!bonusExpiresAt || bonusExpiresAt.getTime() <= Date.now()) return 0;
  return bonusIdentitySlots;
}
