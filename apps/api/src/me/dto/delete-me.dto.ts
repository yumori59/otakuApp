import { IsNotEmpty, IsOptional, IsString } from 'class-validator';

/**
 * `DELETE /v1/me` のボディ（account-deletion/api-contract-delta.md §1）。
 * ボディ全体が任意で、両キーとも省略できる（Apple / Google のみのアカウントは空ボディで削除する）。
 *
 * `password` に長さ下限を掛けない（`LoginDto` と同じ判断）。
 * 旧ポリシーで作られた短いパスワードのアカウントを 400 と 401 で区別させないため。
 * 必須判定は `users.password_hash` を見ないとできないので UseCase 側で行う。
 *
 * 対象ユーザーは常に Bearer の `sub`。ここに user_id 等を**足さない**（BE-4）。
 */
export class DeleteMeDto {
  @IsOptional()
  @IsString()
  @IsNotEmpty()
  password?: string;

  @IsOptional()
  @IsString()
  @IsNotEmpty()
  apple_authorization_code?: string;
}
