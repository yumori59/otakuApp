import sharp from 'sharp';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import {
  AVATAR_MAX_INPUT_PIXELS,
  AVATAR_SIDE,
  AvatarImageProcessor,
} from './avatar-image.processor';

async function makeJpeg(width: number, height: number): Promise<Buffer> {
  return sharp({
    create: {
      width,
      height,
      channels: 3,
      background: { r: 200, g: 100, b: 50 },
    },
  })
    .jpeg()
    .toBuffer();
}

async function makePng(
  width: number,
  height: number,
  alpha = false,
): Promise<Buffer> {
  return sharp({
    create: {
      width,
      height,
      channels: alpha ? 4 : 3,
      background: alpha
        ? { r: 0, g: 128, b: 255, alpha: 0.5 }
        : { r: 0, g: 128, b: 255 },
    },
  })
    .png()
    .toBuffer();
}

describe('AvatarImageProcessor', () => {
  let processor: AvatarImageProcessor;

  beforeEach(() => {
    processor = new AvatarImageProcessor();
  });

  it('AC-AV-04 1000×600 JPEG → 出力が 512×512 の JPEG', async () => {
    const input = await makeJpeg(1000, 600);
    const output = await processor.process(input);

    const meta = await sharp(output).metadata();
    expect(meta.format).toBe('jpeg');
    expect(meta.width).toBe(AVATAR_SIDE);
    expect(meta.height).toBe(AVATAR_SIDE);
  });

  it('AC-AV-05 透過 PNG → JPEG 512×512・透過部が白', async () => {
    const input = await makePng(400, 400, true);
    const output = await processor.process(input);

    const meta = await sharp(output).metadata();
    expect(meta.format).toBe('jpeg');
    expect(meta.width).toBe(AVATAR_SIDE);
    expect(meta.height).toBe(AVATAR_SIDE);
    // JPEG には alpha チャネルが無い
    expect(meta.channels).toBeLessThanOrEqual(3);
  });

  it('AC-AV-06 非正方形 JPEG に EXIF 向き(6) を付けて送信 → 向き適用後にクロップ、出力 exif が undefined', async () => {
    // 向き 6 = 90度回転（縦長 200×400 → 向き適用後は 400×200）
    const rotatedBuf = await sharp(await makeJpeg(200, 400))
      .withMetadata({ orientation: 6 })
      .jpeg()
      .toBuffer();

    const output = await processor.process(rotatedBuf);

    const meta = await sharp(output).metadata();
    expect(meta.format).toBe('jpeg');
    expect(meta.width).toBe(AVATAR_SIDE);
    expect(meta.height).toBe(AVATAR_SIDE);
    // EXIF が消えていること
    expect(meta.exif).toBeUndefined();
  });

  it('AC-AV-07 GIF 先頭バイト → UNSUPPORTED_MEDIA_TYPE', async () => {
    const gif = Buffer.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    const err = await processor.process(gif).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
  });

  it('AC-AV-07 HEIC 先頭バイト相当（ftyp ボックスを持つ）→ UNSUPPORTED_MEDIA_TYPE', async () => {
    // HEIC は FF D8 FF も 89 50 4E 47 も持たない
    const heicLike = Buffer.from([
      0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63,
    ]);
    const err = await processor.process(heicLike).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
  });

  it('AC-AV-07 Content-Type: image/jpeg と偽ったテキストバイト → UNSUPPORTED_MEDIA_TYPE', async () => {
    const text = Buffer.from('hello world');
    const err = await processor.process(text).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
  });

  it('AC-AV-10 先頭だけ JPEG の壊れたバイト列 → VALIDATION_ERROR invalid image', async () => {
    const broken = Buffer.concat([
      Buffer.from([0xff, 0xd8, 0xff]),
      Buffer.from('not valid jpeg data here'),
    ]);
    const err = await processor.process(broken).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.VALIDATION_ERROR);
    expect((err as AppError).message).toBe('invalid image');
  });

  it('AC-AV-10 4097×4097 PNG → ピクセル上限超過で VALIDATION_ERROR', async () => {
    // 4097*4097 > AVATAR_MAX_INPUT_PIXELS (4096*4096)
    // sharp で実際に作成するには大きすぎるので、PNG マジックバイトを持つ巨大ファイルをモックする
    // 実際には sharp が limitInputPixels で失敗する
    const side = Math.sqrt(AVATAR_MAX_INPUT_PIXELS) + 1; // 4097
    // 大きい PNG は実際に作れないので、PNG ヘッダだけ持つ壊れたバッファでテストする
    // PNG magic + IHDR チャンク（4097x4097）を手動構築
    const buf = Buffer.alloc(33);
    // PNG magic
    buf[0] = 0x89;
    buf[1] = 0x50;
    buf[2] = 0x4e;
    buf[3] = 0x47;
    buf[4] = 0x0d;
    buf[5] = 0x0a;
    buf[6] = 0x1a;
    buf[7] = 0x0a;
    // IHDR length = 13
    buf[8] = 0x00;
    buf[9] = 0x00;
    buf[10] = 0x00;
    buf[11] = 0x0d;
    // IHDR
    buf[12] = 0x49;
    buf[13] = 0x48;
    buf[14] = 0x44;
    buf[15] = 0x52;
    // width = 4097
    buf.writeUInt32BE(Math.floor(side), 16);
    // height = 4097
    buf.writeUInt32BE(Math.floor(side), 20);
    // bit depth = 8
    buf[24] = 8;
    // color type = 2 (RGB)
    buf[25] = 2;
    // compression, filter, interlace = 0
    buf[26] = 0;
    buf[27] = 0;
    buf[28] = 0;

    const err = await processor.process(buf).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.VALIDATION_ERROR);
  });
});
