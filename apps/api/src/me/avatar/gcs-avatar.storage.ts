import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Storage } from '@google-cloud/storage';
import { AvatarStorage } from './avatar.storage';

/**
 * Google Cloud Storage 実装。
 * - `GCS_API_ENDPOINT` があれば fake-gcs-server（ローカル開発）に接続。認証なし。
 * - 無ければ ADC（本番 Cloud Run の実行 SA）。
 * - `AVATAR_BUCKET` 空のときは `isConfigured() === false`。Storage クライアントは遅延生成。
 */
@Injectable()
export class GcsAvatarStorage extends AvatarStorage {
  private readonly logger = new Logger(GcsAvatarStorage.name);
  private _client: Storage | null = null;

  constructor(private readonly config: ConfigService) {
    super();
  }

  isConfigured(): boolean {
    return !!this.bucket;
  }

  async put(objectKey: string, jpeg: Buffer): Promise<void> {
    const bucket = this.bucket;
    if (!bucket) return;
    const file = this.client.bucket(bucket).file(objectKey);
    await file.save(jpeg, {
      contentType: 'image/jpeg',
      metadata: {
        cacheControl: 'private, max-age=31536000, immutable',
      },
      resumable: false,
    });
  }

  async delete(objectKey: string): Promise<void> {
    const bucket = this.bucket;
    if (!bucket) return;
    try {
      await this.client.bucket(bucket).file(objectKey).delete();
    } catch (err: unknown) {
      // 404 は既に削除済みなので無視
      if (isNotFoundError(err)) return;
      throw err;
    }
  }

  publicUrl(objectKey: string): string | null {
    const bucket = this.bucket;
    if (!bucket) return null;
    const base =
      this.config.get<string>('AVATAR_PUBLIC_BASE_URL') ||
      `https://storage.googleapis.com/${bucket}`;
    return `${base}/${objectKey}`;
  }

  private get bucket(): string | undefined {
    return this.config.get<string>('AVATAR_BUCKET') || undefined;
  }

  private get client(): Storage {
    if (!this._client) {
      const endpoint = this.config.get<string>('GCS_API_ENDPOINT');
      if (endpoint) {
        this._client = new Storage({
          apiEndpoint: endpoint,
          projectId: 'local',
        });
      } else {
        this._client = new Storage();
      }
    }
    return this._client;
  }
}

function isNotFoundError(err: unknown): boolean {
  if (err && typeof err === 'object') {
    const code = (err as { code?: unknown }).code;
    if (code === 404 || code === '404') return true;
    // @google-cloud/storage が ApiError を返す場合
    const message = (err as { message?: unknown }).message;
    if (typeof message === 'string' && message.includes('No such object')) {
      return true;
    }
  }
  return false;
}
