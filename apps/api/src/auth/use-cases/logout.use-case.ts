import { Injectable } from '@nestjs/common';
import { AuthService } from '../auth.service';
import { LogoutDto } from '../dto/logout.dto';

/**
 * 提示された refresh token を失効させる（FR-AUTH-5）。
 * 未知・失効済みでも成功扱い（冪等・情報を漏らさない）。
 */
@Injectable()
export class LogoutUseCase {
  constructor(private readonly auth: AuthService) {}

  async execute(dto: LogoutDto): Promise<void> {
    await this.auth.revokeRefreshTokenByRaw(dto.refresh_token);
  }
}
