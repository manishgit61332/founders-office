import vinextWorker from 'vinext/server/fetch-handler';
import { securityHeaders } from './security-headers';

type VinextEnvironment = Parameters<typeof vinextWorker.fetch>[1];
type VinextContext = Parameters<typeof vinextWorker.fetch>[2];

const worker = {
  async fetch(
    request: Request,
    environment: VinextEnvironment,
    context: VinextContext,
  ) {
    const response = await vinextWorker.fetch(request, environment, context);
    const headers = new Headers(response.headers);

    for (const { key, value } of securityHeaders) {
      headers.set(key, value);
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};

export default worker;
