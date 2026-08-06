# docs/plans/

機能単位の計画産物（`aidlc-planner` の出力先）を置くディレクトリ。

推奨構成:

```
docs/plans/<feature>/
  questions-requirements.md
  requirements.md
  plan.md
  review.md          # code-reviewer 結果（任意）
```

日付プレフィックスでも可: `docs/plans/2026-08-01-<feature>/`。

横断進捗は [`STATUS.md`](./STATUS.md)。**仕様の正は `docs/00`〜`09`**。

> **2026-08-05**: アプリ不要の独立共有 Web（Next.js）は作らない。過去計画（`ios-network-integration` 等）に「Next.js 共有 Web / roadmap 1-7」とある記述は履歴として残し、現行方針は STATUS と `docs/00`〜`09` を正とする。
