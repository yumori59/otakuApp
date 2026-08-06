import { Body, Controller, Get, Param, Patch, Res } from '@nestjs/common';
import { Public } from '../common/decorators/public.decorator';
import { ThrottleShareWrite } from '../common/throttling/throttle-route.decorators';
import { UpdateShareItemDto } from './dto/update-share-item.dto';
import {
  PublicSharePayload,
  TourShareWriteItem,
} from './public-share.presenter';
import { ResolveShareUseCase } from './use-cases/resolve-share.use-case';
import { UpdateShareItemUseCase } from './use-cases/update-share-item.use-case';

/** express の Response 型に依存しないための最小形（AllExceptionsFilter と同じ方針）。 */
interface ResponseLike {
  setHeader(name: string, value: string): unknown;
}

/** 検索エンジンにインデックスさせない（docs/09 L3 / AC-SH-20）。 */
export const ROBOTS_TAG_HEADER = 'X-Robots-Tag';
export const ROBOTS_TAG_VALUE = 'noindex, nofollow';

/**
 * api-contract.md §8 `GET /public/shares/:token` と
 * api-contract-delta.md §4 `PATCH /public/shares/:token/items/:item_key`。
 *
 * **意図的に認証不要**（`@Public()`）。出力は必ずマスキング済みペイロードだけ（BE-4）。
 * `/v1` プレフィックスは app.setup.ts の `GLOBAL_PREFIX_EXCLUDE` で外れる
 * （**PATCH のパスも exclude に入っている必要がある**）。
 */
@Controller('public/shares')
export class PublicController {
  constructor(
    private readonly resolveShare: ResolveShareUseCase,
    private readonly updateShareItem: UpdateShareItemUseCase,
  ) {}

  @Public()
  @Get(':token')
  getShare(
    @Param('token') token: string,
    @Res({ passthrough: true }) res: ResponseLike,
  ): Promise<PublicSharePayload> {
    // 成功・SHARE_INVALID 404 のどちらでも付くよう、解決前にヘッダを立てる
    res.setHeader(ROBOTS_TAG_HEADER, ROBOTS_TAG_VALUE);
    return this.resolveShare.execute(token);
  }

  /** 共有先による軽量編集。レートは token 単位で 60 回/分（ThrottleShareWrite）。 */
  @Public()
  @ThrottleShareWrite()
  @Patch(':token/items/:item_key')
  patchShareItem(
    @Param('token') token: string,
    @Param('item_key') itemKey: string,
    @Body() dto: UpdateShareItemDto,
    @Res({ passthrough: true }) res: ResponseLike,
  ): Promise<TourShareWriteItem> {
    res.setHeader(ROBOTS_TAG_HEADER, ROBOTS_TAG_VALUE);
    return this.updateShareItem.execute(token, itemKey, dto);
  }
}
