// Unit tests for the OSRM helpers. Run: node --test supabase/tests/edge/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildRouteUrl, parseRouteResponse } from '../../functions/_shared/osrm.ts';

test('URL uses lng,lat order, keeps stop order and asks for the full polyline6 geometry', () => {
  const u = buildRouteUrl('https://osrm.example/', [{ latitude: 11.6234, longitude: 92.7265 }, { latitude: 13.27, longitude: 93.0 }]);
  assert.ok(u.startsWith('https://osrm.example/route/v1/driving/92.726500,11.623400;93.000000,13.270000?'));
  assert.ok(u.includes('overview=full') && u.includes('geometries=polyline6'));
});

test('a route needs two stops', () => {
  assert.throws(() => buildRouteUrl('https://x', [{ latitude: 1, longitude: 1 }]));
});

test('only a real OSRM route is accepted', () => {
  const r = parseRouteResponse({ code: 'Ok', routes: [{ geometry: '_p~iF~ps|U_ulLnnqC', distance: 1234.5, duration: 99 }] });
  assert.deepEqual(r, { polyline6: '_p~iF~ps|U_ulLnnqC', distanceM: 1234.5, durationS: 99 });
});

test('NoRoute / empty geometry is an error, never a straight line', () => {
  assert.throws(() => parseRouteResponse({ code: 'NoRoute', message: 'x' }), /could not find a road route/);
  assert.throws(() => parseRouteResponse({ code: 'Ok', routes: [] }), /no geometry/);
  assert.throws(() => parseRouteResponse(null));
});
