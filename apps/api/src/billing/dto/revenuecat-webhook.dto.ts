import {
  IsNotEmpty,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';

export class RevenueCatEventDto {
  @IsString()
  @IsNotEmpty()
  type!: string;

  @IsString()
  @IsNotEmpty()
  app_user_id!: string;

  @IsOptional()
  @IsString()
  product_id?: string;

  @IsOptional()
  @IsNumber()
  expiration_at_ms?: number;
}

export class RevenueCatWebhookDto {
  @IsOptional()
  @IsString()
  api_version?: string;

  @IsObject()
  @ValidateNested()
  @Type(() => RevenueCatEventDto)
  event!: RevenueCatEventDto;
}
