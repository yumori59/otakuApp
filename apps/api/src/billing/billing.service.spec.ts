import { UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../prisma/prisma.service';
import { BillingService } from './billing.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';

describe('BillingService', () => {
  let prisma: {
    user: { findUnique: jest.Mock };
    entitlement: { upsert: jest.Mock };
  };
  let config: { get: jest.Mock };
  let service: BillingService;

  beforeEach(() => {
    prisma = {
      user: { findUnique: jest.fn().mockResolvedValue({ id: USER_ID }) },
      entitlement: { upsert: jest.fn().mockResolvedValue({}) },
    };
    config = { get: jest.fn().mockReturnValue('test-secret') };
    service = new BillingService(
      prisma as unknown as PrismaService,
      config as unknown as ConfigService,
    );
  });

  describe('assertAuthorized', () => {
    it('正しい Bearer を受け入れる', () => {
      expect(() =>
        service.assertAuthorized('Bearer test-secret'),
      ).not.toThrow();
    });

    it('不正な Bearer は 401', () => {
      expect(() => service.assertAuthorized('Bearer wrong')).toThrow(
        UnauthorizedException,
      );
    });
  });

  describe('handleWebhook', () => {
    it('INITIAL_PURCHASE で plan=plus', async () => {
      await service.handleWebhook({
        event: {
          type: 'INITIAL_PURCHASE',
          app_user_id: USER_ID,
          product_id: 'plus_monthly',
          expiration_at_ms: 1_785_513_600_000,
        },
      });

      expect(prisma.entitlement.upsert).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { userId: USER_ID },
          create: expect.objectContaining({ plan: 'plus' }),
          update: expect.objectContaining({ plan: 'plus' }),
        }),
      );
    });

    it('EXPIRATION で plan=free', async () => {
      await service.handleWebhook({
        event: {
          type: 'EXPIRATION',
          app_user_id: USER_ID,
        },
      });

      expect(prisma.entitlement.upsert).toHaveBeenCalledWith(
        expect.objectContaining({
          update: expect.objectContaining({ plan: 'free', inGracePeriod: false }),
        }),
      );
    });

    it('BILLING_ISSUE で inGracePeriod=true', async () => {
      await service.handleWebhook({
        event: {
          type: 'BILLING_ISSUE',
          app_user_id: USER_ID,
        },
      });

      expect(prisma.entitlement.upsert).toHaveBeenCalledWith(
        expect.objectContaining({
          update: expect.objectContaining({ inGracePeriod: true }),
        }),
      );
    });

    it('未登録ユーザーは upsert せず no-op', async () => {
      prisma.user.findUnique.mockResolvedValue(null);

      await service.handleWebhook({
        event: {
          type: 'INITIAL_PURCHASE',
          app_user_id: USER_ID,
          product_id: 'plus_monthly',
        },
      });

      expect(prisma.entitlement.upsert).not.toHaveBeenCalled();
    });

    it('不正な UUID は upsert せず no-op', async () => {
      await service.handleWebhook({
        event: {
          type: 'INITIAL_PURCHASE',
          app_user_id: 'not-a-uuid',
        },
      });

      expect(prisma.user.findUnique).not.toHaveBeenCalled();
      expect(prisma.entitlement.upsert).not.toHaveBeenCalled();
    });
  });
});
