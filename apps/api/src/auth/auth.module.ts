import { Module } from '@nestjs/common';
import {
  AppleJwksProvider,
  RemoteAppleJwksProvider,
} from './apple-jwks.provider';
import {
  AppleSignInTokenRevoker,
  AppleTokenRevoker,
} from './apple-token.revoker';
import {
  AppleIdentityTokenVerifier,
  AppleTokenVerifier,
} from './apple-token.verifier';
import { AccountIdGenerator } from './account-id.generator';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import {
  GoogleJwksProvider,
  RemoteGoogleJwksProvider,
} from './google-jwks.provider';
import {
  GoogleIdentityTokenVerifier,
  GoogleTokenVerifier,
} from './google-token.verifier';
import { PasswordHasher, ScryptPasswordHasher } from './password.hasher';
import { ChangePasswordUseCase } from './use-cases/change-password.use-case';
import { LoginWithEmailUseCase } from './use-cases/login-with-email.use-case';
import { LogoutUseCase } from './use-cases/logout.use-case';
import { RefreshTokenUseCase } from './use-cases/refresh-token.use-case';
import { RegisterWithEmailUseCase } from './use-cases/register-with-email.use-case';
import { RequestPasswordResetUseCase } from './use-cases/request-password-reset.use-case';
import { ResetPasswordUseCase } from './use-cases/reset-password.use-case';
import { SignInWithAppleUseCase } from './use-cases/sign-in-with-apple.use-case';
import { SignInWithGoogleUseCase } from './use-cases/sign-in-with-google.use-case';

// PrismaModule / EntitlementsModule / MailModule は @Global なので import は不要。
@Module({
  controllers: [AuthController],
  providers: [
    AuthService,
    AccountIdGenerator,
    { provide: AppleJwksProvider, useClass: RemoteAppleJwksProvider },
    { provide: AppleTokenVerifier, useClass: AppleIdentityTokenVerifier },
    { provide: AppleTokenRevoker, useClass: AppleSignInTokenRevoker },
    { provide: GoogleJwksProvider, useClass: RemoteGoogleJwksProvider },
    { provide: GoogleTokenVerifier, useClass: GoogleIdentityTokenVerifier },
    { provide: PasswordHasher, useClass: ScryptPasswordHasher },
    SignInWithAppleUseCase,
    SignInWithGoogleUseCase,
    RegisterWithEmailUseCase,
    LoginWithEmailUseCase,
    ChangePasswordUseCase,
    RequestPasswordResetUseCase,
    ResetPasswordUseCase,
    RefreshTokenUseCase,
    LogoutUseCase,
  ],
  // MeModule が DELETE /v1/me の本人確認（PasswordHasher）と
  // Apple トークン失効（AppleTokenRevoker）に使う（インスタンスを二重に作らない — D6）。
  exports: [PasswordHasher, AppleTokenRevoker],
})
export class AuthModule {}
