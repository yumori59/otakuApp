import 'reflect-metadata';
import { RequestMethod } from '@nestjs/common';
import { METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { ToursController } from './tours.controller';

interface RouteInfo {
  handler: string;
  method: number | undefined;
  path: unknown;
}

function routesOf(controller: new (...args: never[]) => object): RouteInfo[] {
  const proto = controller.prototype as Record<string, unknown>;
  return Object.getOwnPropertyNames(proto)
    .filter((name) => name !== 'constructor')
    .map((name) => ({
      handler: name,
      method: Reflect.getMetadata(METHOD_METADATA, proto[name] as object) as
        | number
        | undefined,
      path: Reflect.getMetadata(PATH_METADATA, proto[name] as object),
    }))
    .filter((route) => route.method !== undefined);
}

describe('ToursController のルート定義', () => {
  it('AC-APP-22 POST /v1/tours のルートが存在しない (D9)', () => {
    const posts = routesOf(ToursController).filter(
      (r) => r.method === RequestMethod.POST,
    );
    expect(posts).toEqual([]);
  });

  it('コントローラのプレフィックスは tours', () => {
    expect(Reflect.getMetadata(PATH_METADATA, ToursController)).toBe('tours');
  });

  it('GET / GET :id / PATCH :id / DELETE :id / GET :id/matrix を提供する', () => {
    const routes = routesOf(ToursController).map(
      (r) => `${r.method}:${String(r.path)}`,
    );
    expect(routes).toEqual(
      expect.arrayContaining([
        `${RequestMethod.GET}:/`,
        `${RequestMethod.GET}::id`,
        `${RequestMethod.GET}::id/matrix`,
        `${RequestMethod.PATCH}::id`,
        `${RequestMethod.DELETE}::id`,
      ]),
    );
  });
});
