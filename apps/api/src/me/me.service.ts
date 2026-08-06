import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import {
  EntitlementsService,
  EntitlementView,
} from '../entitlements/entitlements.service';
import { PrismaService } from '../prisma/prisma.service';
import { UpdateMeDto } from './dto/update-me.dto';

export interface MeUserView {
  id: string;
  email: string | null;
  auth_providers: string[];
  created_at: string;
}

export interface MeProfileView {
  account_id: string | null;
  display_name: string | null;
  username: string | null;
  app_display_name: string | null;
  theme_color: string;
  locale: string;
  timezone: string;
  onboarded_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface MeEntitlementView {
  plan: 'free' | 'plus';
  expires_at: string | null;
  in_grace_period: boolean;
  bonus_identity_slots: number;
  bonus_expires_at: string | null;
  identity_limit: number | null;
  share_limit: number | null;
}

export interface MeView {
  user: MeUserView;
  profile: MeProfileView;
  entitlement: MeEntitlementView;
}

/** `DELETE /v1/me` の本人確認に必要な最小限の users 行（BE-3: UseCase は Prisma を直接見ない）。 */
export interface DeletableUser {
  id: string;
  passwordHash: string | null;
  appleSub: string | null;
}

/** 削除トランザクションの上限（大量データのアカウント対策 — requirements.md §4 D1 / E-6）。 */
const DELETE_TRANSACTION_OPTIONS = { maxWait: 5_000, timeout: 15_000 };

interface UserWithProfile {
  id: string;
  appleSub: string | null;
  googleSub: string | null;
  passwordHash: string | null;
  email: string | null;
  createdAt: Date;
  profile: {
    accountId: string | null;
    displayName: string | null;
    username: string | null;
    appDisplayName: string | null;
    themeColor: string;
    locale: string;
    timezone: string;
    onboardedAt: Date | null;
    createdAt: Date;
    updatedAt: Date;
  } | null;
}

/**
 * `GET /v1/me` / `PATCH /v1/me`（api-contract.md §2）。
 * entitlement は EntitlementsService（読み取り専用・@Global）にのみ委譲する。
 * ここに entitlement への書き込みメソッドを作らない（AC-ME-06 / ADR-002）。
 */
@Injectable()
export class MeService {
  private readonly logger = new Logger(MeService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly entitlements: EntitlementsService,
  ) {}

  async getMe(userId: string): Promise<MeView> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      include: { profile: true },
    });
    if (!user || !user.profile) {
      throw AppError.notFound('user not found');
    }
    return presentMe(
      user as UserWithProfile,
      await loadEntitlement(this.entitlements, userId),
    );
  }

  async updateMe(userId: string, dto: UpdateMeDto): Promise<MeView> {
    const data: Record<string, unknown> = {};
    if (dto.display_name !== undefined) data.displayName = dto.display_name;
    if (dto.username !== undefined) data.username = dto.username;
    if (dto.app_display_name !== undefined) {
      data.appDisplayName = dto.app_display_name;
    }
    if (dto.theme_color !== undefined) data.themeColor = dto.theme_color;
    if (dto.locale !== undefined) data.locale = dto.locale;
    if (dto.timezone !== undefined) data.timezone = dto.timezone;
    if (dto.onboarded_at !== undefined) {
      data.onboardedAt = new Date(dto.onboarded_at);
    }

    // ownerId スコープ: 常に自分の Profile（id === userId）のみ更新する（BE-4）
    await this.prisma.profile.update({ where: { id: userId }, data });

    return this.getMe(userId);
  }

  /**
   * `DELETE /v1/me` の本人確認用に users 行を読む（password_hash の有無で分岐する）。
   * 存在しなければ null（例外にしない）。
   */
  async findUserForDeletion(userId: string): Promise<DeletableUser | null> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, passwordHash: true, appleSub: true },
    });
    return user ?? null;
  }

  /**
   * アカウントと全関連データを 1 トランザクションで物理削除する（FR-AD-1 / FR-AD-4）。
   *
   * **削除順序を変えないこと**（requirements.md §1.1 / §4 D1）。
   * `applications.rep_identity_id` は `onDelete: Restrict` で即時チェックされるため、
   * `applications` を `identities` より先に消さないと FK 違反（P2003）になる。
   * `where` に `deletedAt` の条件は付けない（ソフトデリート済みの行も物理削除する — E-12）。
   */
  async deleteAccount(userId: string): Promise<void> {
    try {
      await this.prisma.$transaction(async (tx) => {
        await tx.applicationCompanion.deleteMany({
          where: { ownerId: userId },
        });
        await tx.application.deleteMany({ where: { ownerId: userId } });
        await tx.membership.deleteMany({ where: { ownerId: userId } });
        await tx.identity.deleteMany({ where: { ownerId: userId } });
        await tx.event.deleteMany({ where: { ownerId: userId } });
        await tx.tour.deleteMany({ where: { ownerId: userId } });
        await tx.shareLink.deleteMany({ where: { ownerId: userId } });
        await tx.deviceToken.deleteMany({ where: { userId } });
        await tx.refreshToken.deleteMany({ where: { userId } });
        await tx.passwordResetCode.deleteMany({ where: { userId } });
        await tx.entitlement.deleteMany({ where: { userId } });
        await tx.profile.deleteMany({ where: { id: userId } });
        await tx.user.delete({ where: { id: userId } });
      }, DELETE_TRANSACTION_OPTIONS);
    } catch (error) {
      // 既に削除済み（2 回目 / 並行削除の後発）は契約どおり 404 に写す（BE-6 / E-1）
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2025'
      ) {
        throw AppError.notFound('user not found');
      }
      throw error;
    }

    // 個人データは出さない（NFR-AD-3 / NFR-AD-6）
    this.logger.log(`account_deleted user_id=${userId}`);
  }
}

async function loadEntitlement(
  entitlements: EntitlementsService,
  userId: string,
): Promise<{
  entitlement: EntitlementView;
  identityLimit: number | null;
  shareLimit: number | null;
}> {
  const [entitlement, identityLimit, shareLimit] = await Promise.all([
    entitlements.get(userId),
    entitlements.identityLimit(userId),
    entitlements.shareLimit(userId),
  ]);
  return { entitlement, identityLimit, shareLimit };
}

function presentMe(
  user: UserWithProfile,
  loaded: {
    entitlement: EntitlementView;
    identityLimit: number | null;
    shareLimit: number | null;
  },
): MeView {
  const profile = user.profile;
  if (!profile) {
    throw AppError.notFound('user not found');
  }
  const { entitlement, identityLimit, shareLimit } = loaded;

  return {
    user: {
      id: user.id,
      email: user.email,
      auth_providers: authProviders(user),
      created_at: user.createdAt.toISOString(),
    },
    profile: {
      account_id: profile.accountId,
      display_name: profile.displayName,
      username: profile.username,
      app_display_name: profile.appDisplayName,
      theme_color: profile.themeColor,
      locale: profile.locale,
      timezone: profile.timezone,
      onboarded_at: profile.onboardedAt
        ? profile.onboardedAt.toISOString()
        : null,
      created_at: profile.createdAt.toISOString(),
      updated_at: profile.updatedAt.toISOString(),
    },
    entitlement: {
      plan: entitlement.plan,
      expires_at: entitlement.expiresAt
        ? entitlement.expiresAt.toISOString()
        : null,
      in_grace_period: entitlement.inGracePeriod,
      bonus_identity_slots: entitlement.bonusIdentitySlots,
      bonus_expires_at: entitlement.bonusExpiresAt
        ? entitlement.bonusExpiresAt.toISOString()
        : null,
      identity_limit: identityLimit,
      share_limit: shareLimit,
    },
  };
}

/**
 * `auth_providers` は apple_sub / google_sub / password_hash の有無から導出する（DB 列を増やさない）。
 * `email` 列は OAuth (apple/google) 経由で取得した連絡先アドレスに過ぎず認証手段の判定に使わない。
 * メール+パスワード認証を持つのは `password_hash` が非 null のときのみ（api-contract-delta.md §2）。
 * 順序は apple → google → email で固定。
 */
function authProviders(user: {
  appleSub: string | null;
  googleSub: string | null;
  passwordHash: string | null;
}): string[] {
  const providers: string[] = [];
  if (user.appleSub) providers.push('apple');
  if (user.googleSub) providers.push('google');
  if (user.passwordHash) providers.push('email');
  return providers;
}
