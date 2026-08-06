import 'reflect-metadata';
import { RequestMethod } from '@nestjs/common';
import { METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { EventsController } from './events.controller';

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

describe('EventsController のルート定義', () => {
  it('AC-APP-22 POST /v1/events のルートが存在しない (D9)', () => {
    const posts = routesOf(EventsController).filter(
      (r) => r.method === RequestMethod.POST,
    );
    expect(posts).toEqual([]);
  });

  it('GET / GET :id / PATCH :id / DELETE :id を提供する', () => {
    const routes = routesOf(EventsController).map(
      (r) => `${r.method}:${String(r.path)}`,
    );
    expect(routes).toEqual(
      expect.arrayContaining([
        `${RequestMethod.GET}:/`,
        `${RequestMethod.GET}::id`,
        `${RequestMethod.PATCH}::id`,
        `${RequestMethod.DELETE}::id`,
      ]),
    );
  });
});
