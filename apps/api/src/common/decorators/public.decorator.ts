import { SetMetadata } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';

/** JwtAuthGuard を素通しさせる。認証不要なエンドポイントにのみ付ける。 */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
