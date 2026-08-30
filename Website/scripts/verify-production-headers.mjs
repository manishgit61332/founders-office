import worker from '../dist/server/index.js';

const expectedHeaders = new Map([
  [
    'content-security-policy',
    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; upgrade-insecure-requests",
  ],
  ['strict-transport-security', 'max-age=31536000; includeSubDomains'],
  ['x-content-type-options', 'nosniff'],
  ['x-frame-options', 'DENY'],
  ['referrer-policy', 'no-referrer'],
  [
    'permissions-policy',
    'camera=(), microphone=(), geolocation=(), payment=()',
  ],
]);

const executionContext = {
  passThroughOnException() {},
  waitUntil() {},
};

for (const route of ['/', '/privacy', '/support', '/security']) {
  const response = await worker.fetch(
    new Request(`https://founders-office.invalid${route}`),
    {},
    executionContext,
  );

  if (response.status !== 200) {
    throw new Error(`${route} returned ${response.status}; expected 200`);
  }

  const contentType = response.headers.get('content-type') ?? '';
  if (!contentType.startsWith('text/html')) {
    throw new Error(
      `${route} returned ${contentType || 'no content type'}; expected HTML`,
    );
  }

  for (const [name, expectedValue] of expectedHeaders) {
    const actualValue = response.headers.get(name);
    if (actualValue !== expectedValue) {
      throw new Error(
        `${route} returned ${name}=${JSON.stringify(actualValue)}; expected ${JSON.stringify(expectedValue)}`,
      );
    }
  }

  await response.body?.cancel();
}

console.log('Production Worker security headers verified on every HTML route.');
