import {
  ArgumentsHost,
  BadRequestException,
  HttpException,
  Logger,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { AllExceptionsFilter } from './all-exceptions.filter';
import { AppError } from '../errors/app-error';
import { ErrorCode } from '../errors/error-codes';

interface HostParts {
  host: ArgumentsHost;
  status: jest.Mock;
  json: jest.Mock;
  setHeader: jest.Mock;
}

function createHost(headers: Record<string, string> = {}): HostParts {
  const json = jest.fn();
  const status = jest.fn().mockReturnValue({ json });
  const setHeader = jest.fn();
  const req = { headers, url: '/v1/identities', method: 'POST' };
  const res = { status, setHeader };
  const host = {
    switchToHttp: () => ({
      getRequest: () => req,
      getResponse: () => res,
    }),
  } as unknown as ArgumentsHost;
  return { host, status, json, setHeader };
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

describe('AllExceptionsFilter', () => {
  let filter: AllExceptionsFilter;

  beforeEach(() => {
    filter = new AllExceptionsFilter();
    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('AC-CORE-01 AppError を {code,message,details,request_id} envelope に正規化する', () => {
    const { host, status, json } = createHost({
      'x-request-id': '018f3c2a-9999-7c90-9d2a-000000000001',
    });

    filter.catch(
      new AppError(
        ErrorCode.PLAN_LIMIT_IDENTITY,
        'identity limit reached (limit=3, current=3)',
        { limit: 3, current: 3 },
      ),
      host,
    );

    expect(status).toHaveBeenCalledWith(403);
    expect(json).toHaveBeenCalledWith({
      code: 'PLAN_LIMIT_IDENTITY',
      message: 'identity limit reached (limit=3, current=3)',
      details: { limit: 3, current: 3 },
      request_id: '018f3c2a-9999-7c90-9d2a-000000000001',
    });
  });

  it('AC-CORE-01 X-Request-Id が無ければ UUID を生成してレスポンスヘッダにも付ける', () => {
    const { host, json, setHeader } = createHost();

    filter.catch(new AppError(ErrorCode.NOT_FOUND, 'not found'), host);

    const body = json.mock.calls[0][0] as { request_id: string };
    expect(body.request_id).toMatch(UUID_RE);
    expect(setHeader).toHaveBeenCalledWith('X-Request-Id', body.request_id);
  });

  it('AC-CORE-01 details が無い AppError では details が null になる', () => {
    const { host, status, json } = createHost();

    filter.catch(new AppError(ErrorCode.NOT_FOUND, 'not found'), host);

    expect(status).toHaveBeenCalledWith(404);
    const body = json.mock.calls[0][0] as Record<string, unknown>;
    expect(body.code).toBe('NOT_FOUND');
    expect(body.details).toBeNull();
  });

  it('AC-CORE-01 ValidationPipe の BadRequestException を VALIDATION_ERROR 400 にする', () => {
    const { host, status, json } = createHost();

    filter.catch(
      new BadRequestException({
        statusCode: 400,
        message: ['relation must be one of the following values: self'],
        error: 'Bad Request',
      }),
      host,
    );

    expect(status).toHaveBeenCalledWith(400);
    const body = json.mock.calls[0][0] as {
      code: string;
      details: { messages: string[] } | null;
    };
    expect(body.code).toBe('VALIDATION_ERROR');
    expect(body.details?.messages).toEqual([
      'relation must be one of the following values: self',
    ]);
  });

  it('AC-CORE-02 未知例外は INTERNAL 500 になり、スタック / 元メッセージを漏らさない', () => {
    const { host, status, json } = createHost();
    const boom = new Error('connect ECONNREFUSED 127.0.0.1:5432 at Socket');

    filter.catch(boom, host);

    expect(status).toHaveBeenCalledWith(500);
    const body = json.mock.calls[0][0] as Record<string, unknown>;
    expect(body.code).toBe('INTERNAL');
    expect(JSON.stringify(body)).not.toContain('ECONNREFUSED');
    expect(JSON.stringify(body)).not.toContain('at Socket');
    expect(body).not.toHaveProperty('stack');
    expect(Object.keys(body).sort()).toEqual([
      'code',
      'details',
      'message',
      'request_id',
    ]);
  });

  it('BE-6 Prisma P2002 (ユニーク制約違反) は CONFLICT 409 になる', () => {
    const { host, status, json } = createHost();

    filter.catch(
      new Prisma.PrismaClientKnownRequestError(
        'Unique constraint failed on the fields: (`id`)',
        { code: 'P2002', clientVersion: '6.19.0', meta: { target: ['id'] } },
      ),
      host,
    );

    expect(status).toHaveBeenCalledWith(409);
    const body = json.mock.calls[0][0] as Record<string, unknown>;
    expect(body.code).toBe(ErrorCode.CONFLICT);
    expect(Object.keys(body).sort()).toEqual([
      'code',
      'details',
      'message',
      'request_id',
    ]);
    // 内部スキーマ（テーブル名・カラム名）を漏らさない
    expect(JSON.stringify(body)).not.toContain('Unique constraint');
  });

  it('BE-6 Prisma P2025 (対象行なし) は NOT_FOUND 404 になる', () => {
    const { host, status, json } = createHost();

    filter.catch(
      new Prisma.PrismaClientKnownRequestError(
        'An operation failed because it depends on one or more records that were required but not found.',
        { code: 'P2025', clientVersion: '6.19.0' },
      ),
      host,
    );

    expect(status).toHaveBeenCalledWith(404);
    const body = json.mock.calls[0][0] as Record<string, unknown>;
    expect(body.code).toBe(ErrorCode.NOT_FOUND);
    expect(body.details).toBeNull();
  });

  it('BE-6 その他の Prisma 既知エラーは INTERNAL 500 のまま', () => {
    const { host, status, json } = createHost();

    filter.catch(
      new Prisma.PrismaClientKnownRequestError('connection pool timeout', {
        code: 'P2024',
        clientVersion: '6.19.0',
      }),
      host,
    );

    expect(status).toHaveBeenCalledWith(500);
    const body = json.mock.calls[0][0] as Record<string, unknown>;
    expect(body.code).toBe(ErrorCode.INTERNAL);
    expect(JSON.stringify(body)).not.toContain('connection pool');
  });

  it('AC-CORE-02 未知例外のスタックはログにだけ出す', () => {
    const errorLog = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    const { host } = createHost();

    filter.catch(new Error('boom'), host);

    expect(errorLog).toHaveBeenCalled();
  });

  it('AC-T0-03 HttpException 429 (ThrottlerException 相当) は RATE_LIMITED envelope で返る', () => {
    const { host, status, json } = createHost({
      'x-request-id': '018f3c2a-9999-7c90-9d2a-000000000002',
    });

    filter.catch(
      new HttpException('ThrottlerException: Too Many Requests', 429),
      host,
    );

    expect(status).toHaveBeenCalledWith(429);
    expect(json).toHaveBeenCalledWith({
      code: 'RATE_LIMITED',
      message: 'ThrottlerException: Too Many Requests',
      details: null,
      request_id: '018f3c2a-9999-7c90-9d2a-000000000002',
    });
  });

  it('AC-SI-T1-03 SHARE_NOT_INVITED は 403 envelope で返る', () => {
    const { host, status, json } = createHost({
      'x-request-id': '018f3c2a-9999-7c90-9d2a-000000000003',
    });

    filter.catch(
      new AppError(ErrorCode.SHARE_NOT_INVITED, 'not invited to this share'),
      host,
    );

    expect(status).toHaveBeenCalledWith(403);
    expect(json).toHaveBeenCalledWith({
      code: 'SHARE_NOT_INVITED',
      message: 'not invited to this share',
      details: null,
      request_id: '018f3c2a-9999-7c90-9d2a-000000000003',
    });
  });

  it('AC-SI-T1-04 SHARE_RECIPIENT_UNKNOWN は 400 + details.unknown_account_ids を保つ', () => {
    const { host, status, json } = createHost({
      'x-request-id': '018f3c2a-9999-7c90-9d2a-000000000004',
    });

    filter.catch(
      new AppError(
        ErrorCode.SHARE_RECIPIENT_UNKNOWN,
        'unknown account id',
        { unknown_account_ids: ['ACC-000000'] },
      ),
      host,
    );

    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith({
      code: 'SHARE_RECIPIENT_UNKNOWN',
      message: 'unknown account id',
      details: { unknown_account_ids: ['ACC-000000'] },
      request_id: '018f3c2a-9999-7c90-9d2a-000000000004',
    });
  });

  it('AC-SI-T1-05 SHARE_RECIPIENT_SELF は 400 envelope で返る', () => {
    const { host, status, json } = createHost({
      'x-request-id': '018f3c2a-9999-7c90-9d2a-000000000005',
    });

    filter.catch(
      new AppError(ErrorCode.SHARE_RECIPIENT_SELF, 'cannot invite yourself'),
      host,
    );

    expect(status).toHaveBeenCalledWith(400);
    expect((json.mock.calls[0][0] as Record<string, unknown>).code).toBe(
      'SHARE_RECIPIENT_SELF',
    );
  });
});
