import { test } from 'node:test';
import assert from 'node:assert/strict';
import { localNetworkAllowed, privateIPv4 } from '../../src/lib/server/local-development.ts';

test('direct phone testing requires explicit dev opt-in, private socket and exact configured host', () => {
  const config = { LOCAL_DIARY: '1', LOCAL_LAN_ENABLED: '1', LOCAL_LAN_HOST: '192.168.1.20' };
  const url = new URL('http://192.168.1.20:5180/diary/home');
  assert.equal(localNetworkAllowed(true, config, url, '192.168.1.30'), true);
  assert.equal(localNetworkAllowed(true, config, url, '::ffff:192.168.1.30'), true);
  for (const [dev, env, target, address] of [
    [false, config, url, '192.168.1.30'],
    [true, { ...config, LOCAL_DIARY: '0' }, url, '192.168.1.30'],
    [true, { ...config, LOCAL_LAN_ENABLED: '0' }, url, '192.168.1.30'],
    [true, { LOCAL_DIARY: '1', LOCAL_LAN_ENABLED: '1' }, url, '192.168.1.30'],
    [true, config, new URL('http://attacker.test:5180'), '192.168.1.30'],
    [true, config, new URL('http://192.168.1.20:3000'), '192.168.1.30'],
    [true, config, url, '203.0.113.5']
  ] as const)
    assert.equal(localNetworkAllowed(dev, env, target, address), false);
});

test('private network parsing rejects public and malformed addresses', () => {
  for (const ip of ['10.1.2.3', '172.16.0.2', '172.31.255.1', '192.168.1.2'])
    assert.equal(privateIPv4(ip), true);
  for (const ip of [
    '127.0.0.1',
    '172.32.0.1',
    '192.168.999.1',
    '192.168.1.2.evil',
    '8.8.8.8',
    'example.com',
    '::1'
  ])
    assert.equal(privateIPv4(ip), false);
});
