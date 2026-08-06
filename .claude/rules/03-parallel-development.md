# Rule 03: 並列開発

## 原則

**可能な限り並列で開発する**。依存がない作業は同時に走らせる。

## 並列実行可

- **BE と iOS の独立作業** — ただし API 契約が確定済みであること
- 異なる NestJS モジュールへの追加（例: identities と shares）
- 異なる iOS Feature ディレクトリへの追加（例: Identities と Applications）
- ドキュメント生成と実装

## 直列必須

- **同一ファイルの編集**（マージ衝突）。特に集中しやすいもの:
  - `apps/api/prisma/schema.prisma`
  - `apps/api/src/app.module.ts`
  - iOS の Network / ApiClient・SyncEngine・Composition Root
- **DB 変更フロー**（schema 編集 → prisma 反映 → service 追従）
- **API 契約の確定 → iOS 追従**（契約前に iOS パースを並列で書かない）

## 実行方法

1. plan に「並列実行可能なタスク」セクションを必ず書く
2. worktree で隔離する場合: `.worktrees/<slug>/` または Claude Code の worktree
3. 同一メッセージ内で複数 Agent を並列発行する

## やってはいけない

- 同一ファイルへの同時編集
- DB 変更中の並列実装
- API 契約未確定のまま BE と iOS を同時走らせる
- レビューの並列スキップ（実装が並列でもレビューは集約）
