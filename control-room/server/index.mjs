import { readFile } from 'node:fs/promises';
import { serverConfig } from './schema.mjs';
import { productionVerifiers } from './auth.mjs';
import { createApp } from './app.mjs';

try {
  const raw = process.env.CONTROL_ROOM_CONFIG_JSON || await readFile(process.env.CONTROL_ROOM_CONFIG || '.private/server.json', 'utf8');
  const config = serverConfig.parse(JSON.parse(raw));
  const app = createApp(config, await productionVerifiers(config));
  await app.listen({ host: '0.0.0.0', port: Number(process.env.PORT || 8080) });
  console.info('IPTV control room ready; region=us-east-2');
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { await app.close(); process.exit(0); });
} catch {
  console.error('Startup failed. Verify private configuration, trusted Roku certificates, and port availability.');
  process.exitCode = 1;
}
