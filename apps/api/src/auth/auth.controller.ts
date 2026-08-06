import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { Public } from '../common/decorators/public.decorator';
import {
  ThrottleAuthEmail,
  ThrottleAuthUser,
  ThrottleResetRequest,
  ThrottleResetSubmit,
} from '../common/throttling/throttle-route.decorators';
import { SignInResponse, TokenPairResponse } from './auth.types';
import { AppleSignInDto } from './dto/apple-sign-in.dto';
import { ChangePasswordDto } from './dto/change-password.dto';
import { GoogleSignInDto } from './dto/google-sign-in.dto';
import { LoginDto } from './dto/login.dto';
import { LogoutDto } from './dto/logout.dto';
import { RefreshDto } from './dto/refresh.dto';
import { RegisterDto } from './dto/register.dto';
import { ResetPasswordDto } from './dto/reset-password.dto';
import { RequestPasswordResetDto } from './dto/reset-request.dto';
import { ChangePasswordUseCase } from './use-cases/change-password.use-case';
import { LoginWithEmailUseCase } from './use-cases/login-with-email.use-case';
import { LogoutUseCase } from './use-cases/logout.use-case';
import { RefreshTokenUseCase } from './use-cases/refresh-token.use-case';
import { RegisterWithEmailUseCase } from './use-cases/register-with-email.use-case';
import { RequestPasswordResetUseCase } from './use-cases/request-password-reset.use-case';
import { ResetPasswordUseCase } from './use-cases/reset-password.use-case';
import { SignInWithAppleUseCase } from './use-cases/sign-in-with-apple.use-case';
import { SignInWithGoogleUseCase } from './use-cases/sign-in-with-google.use-case';

/**
 * api-contract.md §1 Auth + api-contract-delta.md §1（9 ルート）。
 * トークンを取得するための入口は `@Public()`（BE-4 の意図的公開）。
 * `POST password` だけは Bearer 必須なので `@Public()` を付けない。
 */
@Controller('auth')
export class AuthController {
  constructor(
    private readonly signInWithAppleUseCase: SignInWithAppleUseCase,
    private readonly signInWithGoogleUseCase: SignInWithGoogleUseCase,
    private readonly registerWithEmailUseCase: RegisterWithEmailUseCase,
    private readonly loginWithEmailUseCase: LoginWithEmailUseCase,
    private readonly changePasswordUseCase: ChangePasswordUseCase,
    private readonly requestPasswordResetUseCase: RequestPasswordResetUseCase,
    private readonly resetPasswordUseCase: ResetPasswordUseCase,
    private readonly refreshTokenUseCase: RefreshTokenUseCase,
    private readonly logoutUseCase: LogoutUseCase,
  ) {}

  @Public()
  @Post('apple')
  @HttpCode(HttpStatus.OK)
  signInWithApple(@Body() dto: AppleSignInDto): Promise<SignInResponse> {
    return this.signInWithAppleUseCase.execute(dto);
  }

  @Public()
  @Post('google')
  @HttpCode(HttpStatus.OK)
  signInWithGoogle(@Body() dto: GoogleSignInDto): Promise<SignInResponse> {
    return this.signInWithGoogleUseCase.execute(dto);
  }

  /** 新規リソース（users 行）を作るのでここだけ 201。 */
  @Public()
  @ThrottleAuthEmail()
  @Post('register')
  @HttpCode(HttpStatus.CREATED)
  register(@Body() dto: RegisterDto): Promise<SignInResponse> {
    return this.registerWithEmailUseCase.execute(dto);
  }

  @Public()
  @ThrottleAuthEmail()
  @Post('login')
  @HttpCode(HttpStatus.OK)
  login(@Body() dto: LoginDto): Promise<SignInResponse> {
    return this.loginWithEmailUseCase.execute(dto);
  }

  /** 認証必須。`@Public()` を付けないこと（BE-4）。 */
  @ThrottleAuthUser()
  @Post('password')
  @HttpCode(HttpStatus.OK)
  changePassword(
    @CurrentUser() userId: string,
    @Body() dto: ChangePasswordDto,
  ): Promise<TokenPairResponse> {
    return this.changePasswordUseCase.execute(userId, dto);
  }

  /** 登録の有無に関わらず 202 / 空ボディ（アカウント列挙を防ぐ）。 */
  @Public()
  @ThrottleResetRequest()
  @Post('password/reset-request')
  @HttpCode(HttpStatus.ACCEPTED)
  requestPasswordReset(@Body() dto: RequestPasswordResetDto): Promise<void> {
    return this.requestPasswordResetUseCase.execute(dto);
  }

  @Public()
  @ThrottleResetSubmit()
  @Post('password/reset')
  @HttpCode(HttpStatus.OK)
  resetPassword(@Body() dto: ResetPasswordDto): Promise<SignInResponse> {
    return this.resetPasswordUseCase.execute(dto);
  }

  @Public()
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  refresh(@Body() dto: RefreshDto): Promise<TokenPairResponse> {
    return this.refreshTokenUseCase.execute(dto);
  }

  @Public()
  @Post('logout')
  @HttpCode(HttpStatus.NO_CONTENT)
  logout(@Body() dto: LogoutDto): Promise<void> {
    return this.logoutUseCase.execute(dto);
  }
}
