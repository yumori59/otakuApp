import { Reflector } from '@nestjs/core';
import { THROTTLER_SKIP } from '@nestjs/throttler/dist/throttler.constants';
import {
  ThrottleAuthEmail,
  ThrottleAuthUser,
  ThrottleResetRequest,
  ThrottleResetSubmit,
  ThrottleShareWrite,
} from './throttle-route.decorators';
import { ALL_THROTTLER_NAMES, THROTTLER_NAME } from './throttler-config';

const reflector = new Reflector();

function skippedNames(handler: unknown): string[] {
  return ALL_THROTTLER_NAMES.filter((name) =>
    reflector.get(THROTTLER_SKIP + name, handler as never),
  );
}

describe('throttle-route decorators', () => {
  it('AC-T0-05 ThrottleAuthEmail は auth-email だけを残し他を skip する', () => {
    class Target {
      @ThrottleAuthEmail()
      handler() {}
    }
    // eslint-disable-next-line @typescript-eslint/unbound-method -- メタデータ読取のみで呼び出さない
    const skipped = skippedNames(Target.prototype.handler);
    expect(skipped.sort()).toEqual(
      ALL_THROTTLER_NAMES.filter((n) => n !== THROTTLER_NAME.AUTH_EMAIL).sort(),
    );
  });

  it('ThrottleAuthUser は auth-user だけを残す', () => {
    class Target {
      @ThrottleAuthUser()
      handler() {}
    }
    // eslint-disable-next-line @typescript-eslint/unbound-method -- メタデータ読取のみで呼び出さない
    const skipped = skippedNames(Target.prototype.handler);
    expect(skipped).not.toContain(THROTTLER_NAME.AUTH_USER);
    expect(skipped).toContain(THROTTLER_NAME.AUTH_EMAIL);
  });

  it('ThrottleResetRequest は reset-request だけを残す', () => {
    class Target {
      @ThrottleResetRequest()
      handler() {}
    }
    // eslint-disable-next-line @typescript-eslint/unbound-method -- メタデータ読取のみで呼び出さない
    const skipped = skippedNames(Target.prototype.handler);
    expect(skipped).not.toContain(THROTTLER_NAME.RESET_REQUEST);
  });

  it('ThrottleResetSubmit は reset-submit だけを残す', () => {
    class Target {
      @ThrottleResetSubmit()
      handler() {}
    }
    // eslint-disable-next-line @typescript-eslint/unbound-method -- メタデータ読取のみで呼び出さない
    const skipped = skippedNames(Target.prototype.handler);
    expect(skipped).not.toContain(THROTTLER_NAME.RESET_SUBMIT);
  });

  it('ThrottleShareWrite は share-write だけを残す', () => {
    class Target {
      @ThrottleShareWrite()
      handler() {}
    }
    // eslint-disable-next-line @typescript-eslint/unbound-method -- メタデータ読取のみで呼び出さない
    const skipped = skippedNames(Target.prototype.handler);
    expect(skipped).not.toContain(THROTTLER_NAME.SHARE_WRITE);
  });
});
