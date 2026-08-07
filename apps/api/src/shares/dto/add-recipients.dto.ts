import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsString,
  Matches,
} from 'class-validator';
import { ACCOUNT_ID_RE, MAX_SHARED_WITH_ACCOUNT_IDS } from './create-share.dto';

/**
 * `POST /v1/shares/:id/recipients` のリクエストボディ (api-contract-delta.md §3.1)。
 * 形式検証は `CreateShareDto.shared_with_account_ids` と同一にする（1 件あたりの上限）。
 * **合計 20 件上限**（既存招待 + 今回追加分）は形式だけでは判定できないため use-case で見る。
 */
export class AddRecipientsDto {
  @IsArray()
  @ArrayMinSize(1, {
    message: 'account_ids must contain at least one account id',
  })
  @ArrayMaxSize(MAX_SHARED_WITH_ACCOUNT_IDS)
  @IsString({ each: true })
  @Matches(ACCOUNT_ID_RE, {
    each: true,
    message: 'account_ids must match ACC-XXXXXX (uppercase hex)',
  })
  account_ids!: string[];
}
