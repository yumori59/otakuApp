import { ExecutionContext, createParamDecorator } from '@nestjs/common';
import { AppError } from '../errors/app-error';

export interface AuthenticatedUser {
  id: string;
}

/**
 * JwtAuthGuard が req.user に載せた認証ユーザー ID を取り出す。
 * `@CurrentUser() userId: string`
 */
export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): string => {
    const req = ctx
      .switchToHttp()
      .getRequest<{ user?: AuthenticatedUser }>();
    const id = req?.user?.id;
    if (!id) {
      // Guard を通っていない経路で使われた場合の保険（BE-4）
      throw AppError.unauthenticated();
    }
    return id;
  },
);
