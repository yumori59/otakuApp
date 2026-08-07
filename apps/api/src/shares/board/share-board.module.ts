import { Module } from '@nestjs/common';

/**
 * 共有 board のペイロード組み立て・マスキング（share-account-invites）。
 *
 * **枠だけ（T1）**。T2 が `src/public/` の以下を中身を変えずにここへ移設する
 * （api-contract-delta.md §5 の表）:
 * `public-share.presenter.ts` / `identity-summary.service.ts` /
 * `shared-applications.service.ts` / `share-item-key.ts` / `share-write.ts` /
 * `dto/update-share-item.dto.ts` / `use-cases/resolve-share.use-case.ts` /
 * `use-cases/update-share-item.use-case.ts` と対応 spec。
 *
 * コントローラは持たない（ルートは `shares/received/` 側が持つ）。
 */
@Module({})
export class ShareBoardModule {}
