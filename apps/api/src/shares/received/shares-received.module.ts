import { Module } from '@nestjs/common';

/**
 * 受け取り側の共有 API（api-contract-delta.md §4 / share-account-invites）。
 * `GET /v1/shares/received` / `GET /v1/shares/received/:id` /
 * `PATCH /v1/shares/received/:id/items/:item_key` /
 * `POST /v1/shares/received/redeem` / `POST|DELETE /v1/shares/received/:id/hide`。
 *
 * **枠だけ（T1）**。controller / use-cases は T4（読み取り）と T5（PATCH）が足す。
 * **全ルート Bearer 必須。`@Public()` を付けない**（BE-4）。
 */
@Module({})
export class SharesReceivedModule {}
