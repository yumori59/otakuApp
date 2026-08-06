import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { PasswordResetCode, RefreshToken, User } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { randomToken, sha256Hex } from '../common/util/hash.util';
import {
  EntitlementsService,
  Plan,
} from '../entitlements/entitlements.service';
import { PrismaService } from '../prisma/prisma.service';
import { AccountIdGenerator } from './account-id.generator';
import { AppleIdentityClaims } from './apple-token.verifier';
import { GoogleIdentityClaims } from './google-token.verifier';
import {
  RESET_CODE_MAX_ATTEMPTS,
  RESET_CODE_TTL_MINUTES,
  generateResetCode,
  resetCodeHash,
} from './reset-code.generator';

/** 既定値は plan.md §3.7（.env.example）と揃える。 */
export const DEFAULT_ACCESS_TTL_SECONDS = 3600;
export const DEFAULT_REFRESH_TTL_DAYS = 30;

const DAY_MS = 24 * 60 * 60 * 1000;
const MINUTE_MS = 60 * 1000;

export interface IssuedAccessToken {
  accessToken: string;
  expiresIn: number;
}

export interface IssuedRefreshToken {
  id: string;
  /** 生トークン。レスポンスにだけ載せ、DB には sha256 のみ保存する。 */
  token: string;
  expiresAt: Date;
}

/** サインイン系レスポンスの user ブロックの素。 */
export interface AuthUser {
  userId: string;
  accountId: string | null;
  displayName: string | null;
  plan: Plan;
  isNew: boolean;
}

/** @deprecated `AuthUser` を使う（Apple 専用ではなくなったため）。 */
export type AppleUser = AuthUser;

export interface CreateEmailUserInput {
  /** 入力どおりの値を users.email に保存する。 */
  email: string;
  /** trim().toLowerCase() 済みの値。ユニーク判定はこちらで行う。 */
  emailNormalized: string;
  passwordHash: string;
}

/**
 * auth のドメイン処理と Prisma アクセス（ADR-009 の Service 層）。
 * Controller / UseCase から Prisma を直接触らせない（BE-3）。
 */
@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly accountIds: AccountIdGenerator,
    private readonly entitlements: EntitlementsService,
  ) {}

  /**
   * apple_sub でユーザーを find-or-create する（FR-AUTH-2）。
   * 新規時は users / profiles / entitlements を同一トランザクションで作る。
   * email は初回のみ保存し、再ログインでは既存値を上書きしない（FR-AUTH-8 / AC-AUTH-09）。
   */
  async findOrCreateAppleUser(claims: AppleIdentityClaims): Promise<AuthUser> {
    const existing = await this.prisma.user.findUnique({
      where: { appleSub: claims.sub },
      include: { profile: true },
    });

    if (existing) return this.toExistingUser(existing);

    try {
      return await this.accountIds.issue((accountId) =>
        this.prisma.$transaction(async (tx) => {
          const userId = randomUUID();
          await tx.user.create({
            data: { id: userId, appleSub: claims.sub, email: claims.email },
          });
          const profile = await tx.profile.create({
            data: { id: userId, accountId },
          });
          await tx.entitlement.create({ data: { userId, plan: 'free' } });

          return {
            userId,
            accountId: profile.accountId,
            displayName: profile.displayName,
            plan: 'free' as Plan,
            isNew: true,
          };
        }),
      );
    } catch (error) {
      // 同一 apple_sub の同時初回サインイン: 先に作られた行を読み直す（後発は is_new: false）
      if (!isUniqueViolationOn(error, 'applesub')) throw error;
      const created = await this.prisma.user.findUnique({
        where: { appleSub: claims.sub },
        include: { profile: true },
      });
      if (!created) throw error;
      return this.toExistingUser(created);
    }
  }

  /**
   * google_sub でユーザーを find-or-create する（FR-GA-2）。
   * `findOrCreateAppleUser` と同形。email は `email_verified === true` のときだけ
   * verifier が値を入れており、既存ユーザーでは上書きしない（api-contract-delta.md §1）。
   */
  async findOrCreateGoogleUser(
    claims: GoogleIdentityClaims,
  ): Promise<AuthUser> {
    const existing = await this.prisma.user.findUnique({
      where: { googleSub: claims.sub },
      include: { profile: true },
    });

    if (existing) return this.toExistingUser(existing);

    try {
      return await this.accountIds.issue((accountId) =>
        this.prisma.$transaction(async (tx) => {
          const userId = randomUUID();
          await tx.user.create({
            data: { id: userId, googleSub: claims.sub, email: claims.email },
          });
          const profile = await tx.profile.create({
            data: { id: userId, accountId },
          });
          await tx.entitlement.create({ data: { userId, plan: 'free' } });

          return {
            userId,
            accountId: profile.accountId,
            displayName: profile.displayName,
            plan: 'free' as Plan,
            isNew: true,
          };
        }),
      );
    } catch (error) {
      // 同一 google_sub の同時初回サインイン: 先に作られた行を読み直す（AC-GA-12 / BE-6）
      if (!isUniqueViolationOn(error, 'googlesub')) throw error;
      const created = await this.prisma.user.findUnique({
        where: { googleSub: claims.sub },
        include: { profile: true },
      });
      if (!created) throw error;
      return this.toExistingUser(created);
    }
  }

  /**
   * email + password の新規ユーザーを作る（FR-EP-1）。
   * users / profiles / entitlements を同一トランザクションで作る。
   * email_normalized のユニーク制約違反は EMAIL_ALREADY_REGISTERED 409（AC-EP-05 / BE-6）。
   */
  async createEmailUser(input: CreateEmailUserInput): Promise<AuthUser> {
    try {
      return await this.accountIds.issue((accountId) =>
        this.prisma.$transaction(async (tx) => {
          const userId = randomUUID();
          await tx.user.create({
            data: {
              id: userId,
              email: input.email,
              emailNormalized: input.emailNormalized,
              passwordHash: input.passwordHash,
              passwordUpdatedAt: new Date(),
            },
          });
          const profile = await tx.profile.create({
            data: { id: userId, accountId },
          });
          await tx.entitlement.create({ data: { userId, plan: 'free' } });

          return {
            userId,
            accountId: profile.accountId,
            displayName: profile.displayName,
            plan: 'free' as Plan,
            isNew: true,
          };
        }),
      );
    } catch (error) {
      if (isUniqueViolationOn(error, 'emailnormalized')) {
        throw emailAlreadyRegistered();
      }
      throw error;
    }
  }

  /** 正規化済み email でユーザーを引く（login / リセットの起点）。 */
  async findByEmailNormalized(emailNormalized: string): Promise<User | null> {
    return this.prisma.user.findUnique({ where: { emailNormalized } });
  }

  /** userId でユーザーを引く（パスワード変更）。 */
  async findUserById(userId: string): Promise<User | null> {
    return this.prisma.user.findUnique({ where: { id: userId } });
  }

  /** サインイン済みユーザーのレスポンス用サマリ（is_new は常に false）。 */
  async loadUser(userId: string): Promise<AuthUser | null> {
    const row = await this.prisma.user.findUnique({
      where: { id: userId },
      include: { profile: true },
    });
    if (!row) return null;
    return this.toExistingUser(row);
  }

  /** 既定パラメータが変わったときの再ハッシュ保存（AC-EP-10）。 */
  async updatePasswordHash(userId: string, passwordHash: string): Promise<void> {
    await this.prisma.user.update({
      where: { id: userId },
      data: { passwordHash },
    });
  }

  /**
   * パスワードを差し替え、その user の refresh token を全件失効させて
   * 新しい refresh token を 1 本発行する（同一トランザクション・AC-EP-11）。
   */
  async changePassword(
    userId: string,
    passwordHash: string,
  ): Promise<IssuedRefreshToken> {
    const next = this.buildRefreshToken();
    const now = new Date();

    return this.prisma.$transaction(async (tx) => {
      await tx.user.update({
        where: { id: userId },
        data: { passwordHash, passwordUpdatedAt: now },
      });
      await tx.refreshToken.updateMany({
        where: { userId, revokedAt: null },
        data: { revokedAt: now },
      });
      await tx.refreshToken.create({
        data: {
          id: next.id,
          userId,
          tokenHash: sha256Hex(next.token),
          expiresAt: next.expiresAt,
        },
      });
      return next;
    });
  }

  /**
   * リセットコードを発行する（FR-PR-3）。
   * 同一ユーザーの未使用コードは先にすべて失効させ、有効なのは常に最新 1 本だけにする（AC-PR-03）。
   * 戻り値の平文コードはメール本文にのみ使い、DB には sha256 のみ保存する。
   */
  async issueResetCode(userId: string): Promise<string> {
    const code = generateResetCode();
    const now = new Date();

    await this.prisma.$transaction(async (tx) => {
      await tx.passwordResetCode.updateMany({
        where: { userId, usedAt: null },
        data: { usedAt: now },
      });
      await tx.passwordResetCode.create({
        data: {
          id: randomUUID(),
          userId,
          codeHash: resetCodeHash(userId, code),
          expiresAt: new Date(now.getTime() + RESET_CODE_TTL_MINUTES * MINUTE_MS),
        },
      });
    });

    return code;
  }

  /**
   * 提示されたコードに対応する有効な行を引く。
   * 使用済み / 期限切れ（ちょうども含む）/ 試行超過は null（理由を区別しない・AC-PR-09）。
   */
  async findActiveResetCode(
    userId: string,
    code: string,
  ): Promise<PasswordResetCode | null> {
    const row = await this.prisma.passwordResetCode.findUnique({
      where: { codeHash: resetCodeHash(userId, code) },
    });
    if (!row || row.userId !== userId) return null;
    if (row.usedAt !== null) return null;
    if (row.expiresAt.getTime() <= Date.now()) return null;
    if (row.attemptCount >= RESET_CODE_MAX_ATTEMPTS) return null;
    return row;
  }

  /**
   * コード誤りを 1 回記録する。上限に達したらその場で失効させる（AC-PR-10）。
   * 有効なコードが無いユーザーでは何もしない（存在を漏らさないため例外にしない）。
   */
  async recordResetAttempt(userId: string): Promise<void> {
    const now = new Date();
    const active = await this.prisma.passwordResetCode.findFirst({
      where: { userId, usedAt: null, expiresAt: { gt: now } },
      orderBy: { createdAt: 'desc' },
    });
    if (!active) return;

    const attemptCount = active.attemptCount + 1;
    await this.prisma.passwordResetCode.update({
      where: { id: active.id },
      data: {
        attemptCount,
        ...(attemptCount >= RESET_CODE_MAX_ATTEMPTS ? { usedAt: now } : {}),
      },
    });
  }

  /**
   * リセット成立時の後始末を 1 トランザクションで行う（AC-PR-08）。
   * ①パスワード更新 ②当該コードを使用済み ③他の未使用コードも失効
   * ④その user の refresh token を全件失効 — した上で新しい refresh を 1 本発行する。
   */
  async consumeResetCode(input: {
    userId: string;
    codeId: string;
    passwordHash: string;
  }): Promise<IssuedRefreshToken> {
    const next = this.buildRefreshToken();
    const now = new Date();

    return this.prisma.$transaction(async (tx) => {
      await tx.user.update({
        where: { id: input.userId },
        data: { passwordHash: input.passwordHash, passwordUpdatedAt: now },
      });
      await tx.passwordResetCode.updateMany({
        where: { userId: input.userId, usedAt: null },
        data: { usedAt: now },
      });
      await tx.refreshToken.updateMany({
        where: { userId: input.userId, revokedAt: null },
        data: { revokedAt: now },
      });
      await tx.refreshToken.create({
        data: {
          id: next.id,
          userId: input.userId,
          tokenHash: sha256Hex(next.token),
          expiresAt: next.expiresAt,
        },
      });
      return next;
    });
  }

  private async toExistingUser(row: {
    id: string;
    profile: { accountId: string | null; displayName: string | null } | null;
  }): Promise<AuthUser> {
    const entitlement = await this.entitlements.get(row.id);
    return {
      userId: row.id,
      accountId: row.profile?.accountId ?? null,
      displayName: row.profile?.displayName ?? null,
      plan: entitlement.plan,
      isNew: false,
    };
  }

  /** access JWT（HS256・sub にユーザー ID）を発行する（FR-AUTH-3）。 */
  async issueAccessToken(userId: string): Promise<IssuedAccessToken> {
    const secret = this.config.get<string>('JWT_ACCESS_SECRET');
    if (!secret) {
      // 秘密鍵が無い状態で署名を通さない（無署名トークンを発行しない）
      throw new AppError(
        ErrorCode.INTERNAL,
        'JWT_ACCESS_SECRET is not configured',
      );
    }

    const expiresIn = this.accessTtlSeconds();
    const accessToken = await this.jwt.signAsync(
      { sub: userId },
      { secret, expiresIn },
    );
    return { accessToken, expiresIn };
  }

  /** refresh token を発行する。DB には sha256 hex のみを保存する（AC-AUTH-05）。 */
  async issueRefreshToken(userId: string): Promise<IssuedRefreshToken> {
    const issued = this.buildRefreshToken();
    await this.prisma.refreshToken.create({
      data: {
        id: issued.id,
        userId,
        tokenHash: sha256Hex(issued.token),
        expiresAt: issued.expiresAt,
      },
    });
    return issued;
  }

  /** 生トークンをハッシュして該当行を引く。 */
  async findRefreshToken(rawToken: string): Promise<RefreshToken | null> {
    return this.prisma.refreshToken.findUnique({
      where: { tokenHash: sha256Hex(rawToken) },
    });
  }

  /**
   * refresh token を回転させる（FR-AUTH-4）。
   * 旧行は `revoked_at` / `replaced_by` を立て、新行を同一トランザクションで作る。
   * 既に他のリクエストが失効させていたら null（先勝ち・E-13）。
   */
  async rotateRefreshToken(
    current: RefreshToken,
  ): Promise<IssuedRefreshToken | null> {
    const next = this.buildRefreshToken();
    const revokedAt = new Date();

    return this.prisma.$transaction(async (tx) => {
      const revoked = await tx.refreshToken.updateMany({
        where: { id: current.id, revokedAt: null },
        data: { revokedAt, replacedBy: next.id },
      });
      if (revoked.count === 0) return null;

      await tx.refreshToken.create({
        data: {
          id: next.id,
          userId: current.userId,
          tokenHash: sha256Hex(next.token),
          expiresAt: next.expiresAt,
        },
      });
      return next;
    });
  }

  /** logout 用。該当が無くても例外にしない（冪等・FR-AUTH-5）。 */
  async revokeRefreshTokenByRaw(rawToken: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { tokenHash: sha256Hex(rawToken), revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  private buildRefreshToken(): IssuedRefreshToken {
    return {
      id: randomUUID(),
      token: randomToken(),
      expiresAt: new Date(Date.now() + this.refreshTtlDays() * DAY_MS),
    };
  }

  private accessTtlSeconds(): number {
    return positiveInt(
      this.config.get<string>('JWT_ACCESS_TTL_SECONDS'),
      DEFAULT_ACCESS_TTL_SECONDS,
    );
  }

  private refreshTtlDays(): number {
    return positiveInt(
      this.config.get<string>('REFRESH_TTL_DAYS'),
      DEFAULT_REFRESH_TTL_DAYS,
    );
  }
}

/**
 * Prisma のユニーク制約違反 (P2002) が指定の列由来かどうか。
 * `field` は小文字・アンダースコア無しで渡す（例: `applesub` / `emailnormalized`）。
 * Prisma のバージョン差（apple_sub / appleSub / users_apple_sub_key）を吸収する。
 */
function isUniqueViolationOn(error: unknown, field: string): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const { code, meta } = error as {
    code?: unknown;
    meta?: { target?: unknown };
  };
  if (code !== 'P2002') return false;

  const target = meta?.target;
  const fields = Array.isArray(target) ? target.map(String) : [String(target)];
  return fields
    .map((name) => name.toLowerCase().replace(/_/g, ''))
    .some((name) => name.includes(field));
}

function emailAlreadyRegistered(): AppError {
  return new AppError(
    ErrorCode.EMAIL_ALREADY_REGISTERED,
    'email is already registered',
  );
}

/** 未設定・不正値は既定値にフォールバックする（env のみ。enum 値には使わない）。 */
function positiveInt(raw: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
