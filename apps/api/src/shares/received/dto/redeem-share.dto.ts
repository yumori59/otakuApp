import { IsNotEmpty, IsString } from 'class-validator';

/**
 * `POST /v1/shares/received/redeem` のリクエストボディ（api-contract-delta.md §4.4）。
 * `token` は `meigicho://share/<token>` のディープリンクから渡される opaque な値。
 */
export class RedeemShareDto {
  @IsString()
  @IsNotEmpty()
  token!: string;
}
