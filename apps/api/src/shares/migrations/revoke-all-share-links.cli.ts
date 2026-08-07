/**
 * share-account-invites の移行エントリ（api-contract-delta.md §0.5）。
 * `prisma db push` の後に 1 回だけ実行する。冪等なので再実行しても害はない。
 *
 *   cd apps/api && DATABASE_URL=... npx ts-node src/shares/migrations/revoke-all-share-links.cli.ts
 *   （または npm run migrate:revoke-all-shares）
 */
import { PrismaService } from '../../prisma/prisma.service';
import { RevokeAllShareLinksService } from './revoke-all-share-links.service';

async function main(): Promise<void> {
  const prisma = new PrismaService();
  await prisma.$connect();
  try {
    const revoked = await new RevokeAllShareLinksService(prisma).run();
    process.stdout.write(`revoked_share_links=${revoked}\n`);
  } finally {
    await prisma.$disconnect();
  }
}

void main().catch((error: unknown) => {
  process.stderr.write(`${String(error)}\n`);
  process.exitCode = 1;
});
