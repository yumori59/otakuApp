import {
  IsIn,
  IsNotEmpty,
  IsOptional,
  IsString,
  MaxLength,
  Validate,
  ValidateIf,
  ValidationArguments,
  ValidatorConstraint,
  ValidatorConstraintInterface,
} from 'class-validator';
import { APPLICATION_STATUSES } from '../../applications/dto/application-status';
import type { ApplicationStatus } from '../../applications/dto/application-status';

/** rev は base64url 16 文字だが、長さは契約に固定せず上限だけ持つ。 */
export const MAX_REV_LENGTH = 64;
/** seat の上限（api-contract-delta.md §4）。空文字は空文字として保存する。 */
export const MAX_SEAT_LENGTH = 200;

/**
 * `status` / `seat` の**少なくとも一方**が必要（両方無いボディは 400）。
 * 必須項目の `rev` に付けることで、他項目が省略されても必ず評価される。
 */
@ValidatorConstraint({ name: 'shareItemPatchNotEmpty', async: false })
export class ShareItemPatchNotEmptyConstraint implements ValidatorConstraintInterface {
  validate(_value: unknown, args: ValidationArguments): boolean {
    const dto = args.object as UpdateShareItemDto;
    return dto.status !== undefined || dto.seat !== undefined;
  }

  defaultMessage(): string {
    return 'at least one of status / seat is required';
  }
}

/**
 * `PATCH /public/shares/:token/items/:item_key` のリクエストボディ。
 *
 * **共有先に開放するのは status / seat だけ**。`round_name` / `note` /
 * `ticket_count` / `price_yen` / `companions` / 削除は受け付けない
 * （3 キー以外は `forbidNonWhitelisted` で 400）。
 */
export class UpdateShareItemDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(MAX_REV_LENGTH)
  @Validate(ShareItemPatchNotEmptyConstraint)
  rev!: string;

  // 未知値は 400。黙って applied などに落とさない（BE-2 / FR-AP-7）。
  // `status: null` も 400（@IsOptional() だと null が素通しになるため ValidateIf）
  @ValidateIf((dto: UpdateShareItemDto) => dto.status !== undefined)
  @IsIn(APPLICATION_STATUSES)
  status?: ApplicationStatus;

  // null は「座席を消す」。@IsOptional() は null / undefined を素通しする
  @IsOptional()
  @IsString()
  @MaxLength(MAX_SEAT_LENGTH)
  seat?: string | null;
}
