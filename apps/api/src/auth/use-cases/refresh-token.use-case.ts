import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AuthService } from '../auth.service';
import { TOKEN_TYPE, TokenPairResponse } from '../auth.types';
import { RefreshDto } from '../dto/refresh.dto';

/**
 * refresh token の回転（FR-AUTH-4）。
 * 未知 / 失効済み / 期限切れは理由を区別せず AUTH_REFRESH_INVALID 401（E-13）。
 */
@Injectable()
export class RefreshTokenUseCase {
  constructor(private readonly auth: AuthService) {}

  async execute(dto: RefreshDto): Promise<TokenPairResponse> {
    const current = await this.auth.findRefreshToken(dto.refresh_token);
    if (!current || current.revokedAt !== null) {
      throw refreshInvalid();
    }
    if (current.expiresAt.getTime() <= Date.now()) {
      throw refreshInvalid();
    }

    const rotated = await this.auth.rotateRefreshToken(current);
    // 同時使用は先勝ち。回転に負けた側は新トークンを受け取れない
    if (!rotated) throw refreshInvalid();

    const access = await this.auth.issueAccessToken(current.userId);

    return {
      access_token: access.accessToken,
      refresh_token: rotated.token,
      expires_in: access.expiresIn,
      token_type: TOKEN_TYPE,
    };
  }
}

function refreshInvalid(): AppError {
  return new AppError(
    ErrorCode.AUTH_REFRESH_INVALID,
    'refresh token is invalid or expired',
  );
}
