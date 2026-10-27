import { Injectable } from '@nestjs/common';
import sharp from 'sharp';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';

export const AVATAR_MAX_BYTES = 5 * 1024 * 1024;
export const AVATAR_SIDE = 512;
export const AVATAR_MAX_INPUT_PIXELS = 4096 * 4096;

// JPEG: FF D8 FF
const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff]);
// PNG: 89 50 4E 47 0D 0A 1A 0A
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

sharp.cache(false);
sharp.concurrency(1);

function detectFormat(buf: Buffer): 'jpeg' | 'png' | null {
  if (buf.length >= 3 && buf.subarray(0, 3).equals(JPEG_MAGIC)) return 'jpeg';
  if (buf.length >= 8 && buf.subarray(0, 8).equals(PNG_MAGIC)) return 'png';
  return null;
}

@Injectable()
export class AvatarImageProcessor {
  /**
   * JPEG/PNG 以外は UNSUPPORTED_MEDIA_TYPE、デコード不能・ピクセル超過は VALIDATION_ERROR('invalid image') を投げる。
   * 出力は 512×512 JPEG（EXIF なし）。
   */
  async process(input: Buffer): Promise<Buffer> {
    const format = detectFormat(input);
    if (!format) {
      throw new AppError(
        ErrorCode.UNSUPPORTED_MEDIA_TYPE,
        'unsupported image type (jpeg or png only)',
      );
    }

    try {
      const output = await sharp(input, {
        limitInputPixels: AVATAR_MAX_INPUT_PIXELS,
        failOn: 'error',
        pages: 1,
      })
        .rotate()
        .flatten({ background: '#ffffff' })
        .resize(AVATAR_SIDE, AVATAR_SIDE, { fit: 'cover', position: 'centre' })
        .jpeg({ quality: 85, mozjpeg: true })
        .toBuffer();

      return output;
    } catch {
      throw new AppError(ErrorCode.VALIDATION_ERROR, 'invalid image');
    }
  }
}
