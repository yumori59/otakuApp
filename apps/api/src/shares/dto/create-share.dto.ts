import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsISO8601,
  IsOptional,
  IsString,
  Matches,
  Validate,
  ValidationArguments,
  ValidatorConstraint,
  ValidatorConstraintInterface,
  isUUID,
} from 'class-validator';

/** api-contract.md §0 enum 値。黙って別値へフォールバックしない（BE-2）。 */
export const SHARE_SCOPE_TYPES = ['tour', 'identity_summary'] as const;
export type ShareScopeType = (typeof SHARE_SCOPE_TYPES)[number];

/** api-contract-delta.md §0（`write` は backend-auth-and-shares-extension で追加）。 */
export const SHARE_PERMISSIONS = ['read', 'write'] as const;
export type SharePermission = (typeof SHARE_PERMISSIONS)[number];

/** permission 省略時の既定。既存クライアントの挙動を変えない。 */
export const DEFAULT_SHARE_PERMISSION: SharePermission = 'read';

/** api-contract.md §8。expires_at 省略時の既定と上限。 */
export const DEFAULT_EXPIRES_IN_DAYS = 30;
export const MAX_EXPIRES_IN_DAYS = 365;
export const DAY_MS = 24 * 60 * 60 * 1000;

export const MAX_SHARED_WITH_ACCOUNT_IDS = 20;
/** profiles.account_id の形式（`ACC-` + 大文字 6 桁 hex）。 */
export const ACCOUNT_ID_RE = /^ACC-[0-9A-F]{6}$/;

/**
 * scope_type と scope_id の関係を検証する。
 * - `tour`: scope_id 必須（UUID。バージョンは検証しない — BE-1）
 * - `identity_summary`: scope_id を送ってはいけない（送られたら 400）
 */
@ValidatorConstraint({ name: 'shareScopeId', async: false })
export class ShareScopeIdConstraint implements ValidatorConstraintInterface {
  validate(value: unknown, args: ValidationArguments): boolean {
    const scopeType = (args.object as CreateShareDto).scope_type;
    if (scopeType === 'tour') {
      return typeof value === 'string' && isUUID(value);
    }
    if (scopeType === 'identity_summary') {
      return value === undefined;
    }
    // 未知の scope_type は scope_type 側でエラーになる
    return true;
  }

  defaultMessage(args: ValidationArguments): string {
    const scopeType = (args.object as CreateShareDto).scope_type;
    return scopeType === 'identity_summary'
      ? 'scope_id must not be sent when scope_type is identity_summary'
      : 'scope_id must be a UUID when scope_type is tour';
  }
}

/**
 * `permission: "write"` は `scope_type: "tour"` のみ（api-contract-delta.md §3）。
 * `identity_summary` との組み合わせは 400。未知値は `@IsIn` 側で 400（BE-2）。
 */
@ValidatorConstraint({ name: 'sharePermissionScope', async: false })
export class SharePermissionScopeConstraint implements ValidatorConstraintInterface {
  validate(value: unknown, args: ValidationArguments): boolean {
    if (value !== 'write') return true;
    return (args.object as CreateShareDto).scope_type === 'tour';
  }

  defaultMessage(): string {
    return 'permission=write is only available for scope_type=tour';
  }
}

/** expires_at の上限（now + 365 日）。now 依存なので fake timers で固定できる。 */
@ValidatorConstraint({ name: 'shareExpiresAt', async: false })
export class ShareExpiresAtConstraint implements ValidatorConstraintInterface {
  validate(value: unknown): boolean {
    if (typeof value !== 'string') return false;
    const at = Date.parse(value);
    if (Number.isNaN(at)) return false;
    return at <= Date.now() + MAX_EXPIRES_IN_DAYS * DAY_MS;
  }

  defaultMessage(): string {
    return `expires_at must be within ${MAX_EXPIRES_IN_DAYS} days from now`;
  }
}

/**
 * POST /v1/shares のリクエストボディ (api-contract.md §8)。
 * `id` はサーバー生成のためクライアントからは受け取らない。
 */
export class CreateShareDto {
  @IsIn(SHARE_SCOPE_TYPES)
  scope_type!: ShareScopeType;

  @Validate(ShareScopeIdConstraint)
  scope_id?: string;

  @IsOptional()
  @IsIn(SHARE_PERMISSIONS)
  @Validate(SharePermissionScopeConstraint)
  permission?: SharePermission;

  @IsOptional()
  @IsBoolean()
  mask_member_no?: boolean;

  @IsOptional()
  @IsISO8601()
  @Validate(ShareExpiresAtConstraint)
  expires_at?: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(MAX_SHARED_WITH_ACCOUNT_IDS)
  @IsString({ each: true })
  @Matches(ACCOUNT_ID_RE, {
    each: true,
    message: 'shared_with_account_ids must match ACC-XXXXXX (uppercase hex)',
  })
  shared_with_account_ids?: string[];
}
