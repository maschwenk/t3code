// Isolated RPC adapter around the real broker. No provider process or inference is started.
import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [output, sourceRoot = fileURLToPath(new URL('../../../../', import.meta.url))] = process.argv.slice(2);
if (!output) throw new Error('Usage: node browser_broker.mjs PRIVATE_CONNECTION_FILE [SERVER_SOURCE_ROOT]');
const require = createRequire(resolve(sourceRoot, 'apps/server/package.json'));
const Effect = await import(pathToFileURL(require.resolve('effect/Effect')));
const Stream = await import(pathToFileURL(require.resolve('effect/Stream')));
const NodeServices = await import(pathToFileURL(require.resolve('@effect/platform-node/NodeServices')));
const { WebSocketServer } = createRequire(require.resolve('@effect/platform-node/NodeServices'))('ws');
const Broker = await import(pathToFileURL(resolve(sourceRoot, 'apps/server/src/mcp/PreviewAutomationBroker.ts')));
const broker = await Effect.runPromise(Broker.make.pipe(Effect.provide(NodeServices.layer)));
const token = randomUUID();
const tickets = new Set();
const sockets = new WebSocketServer({ noServer: true, maxPayload: 32 * 1024 * 1024 });
let connected = 0;
let focusCount = 0;
let responseCount = 0;
const server = createServer(async (request, response) => {
  const send = (status, value) => {
    response.writeHead(status, { 'content-type': 'application/json' });
    response.end(JSON.stringify(value));
  };
  if (request.headers.authorization !== `Bearer ${token}`) return send(401, { reason: 'unauthorized' });
  if (request.url === '/api/auth/websocket-ticket') {
    const ticket = randomUUID(); tickets.add(ticket);
    return send(200, { ticket });
  }
  if (request.url === '/status') return send(200, { connected, focusCount, responseCount });
  if (request.url !== '/invoke' || request.method !== 'POST') return send(404, { reason: 'not_found' });
  try {
    let body = '';
    for await (const chunk of request) {
      body += chunk;
      if (body.length > 100_000) throw new Error('Request too large');
    }
    const input = JSON.parse(body);
    const result = await Effect.runPromise(broker.invoke({
      scope: {
        environmentId: 'native-browser-fixture', requestNamespace: 'native-browser-fixture:' + input.threadId,
        thread: { threadId: input.threadId, providerSessionId: 'native-browser-fixture:' + input.threadId, providerInstanceId: 'codex' },
        client: undefined, capabilities: new Set(['preview']), issuedAt: Date.now(),
      },
      operation: input.operation, input: input.input ?? {}, tabId: input.tabId, timeoutMs: input.timeoutMs ?? 15_000,
    }).pipe(Effect.match({
      onSuccess: result => ({ ok: true, result }),
      onFailure: error => ({ ok: false, error: { _tag: error._tag, message: error.message } }),
    })));
    send(200, result);
  } catch (error) { send(400, { error: String(error) }); }
});
server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname !== '/ws' || !tickets.delete(url.searchParams.get('wsTicket'))) { socket.destroy(); return; }
  sockets.handleUpgrade(request, socket, head, ws => sockets.emit('connection', ws));
});
sockets.on('connection', socket => {
  const subscriptions = new Map();
  const send = value => { if (socket.readyState === 1) socket.send(JSON.stringify(value)); };
  socket.on('close', () => { for (const controller of subscriptions.values()) controller.abort(); });
  socket.on('message', async data => {
    const frame = JSON.parse(data.toString());
    if (frame._tag === 'Ping') return send({ _tag: 'Pong' });
    if (frame._tag === 'Interrupt') { subscriptions.get(frame.requestId)?.abort(); return; }
    if (frame._tag !== 'Request') return;
    const success = value => send({ _tag: 'Exit', requestId: frame.id, exit: { _tag: 'Success', value: value ?? null } });
    try {
      switch (frame.tag) {
        case 'previewAutomation.connect': {
          const controller = new AbortController(); subscriptions.set(frame.id, controller);
          const stream = await Effect.runPromise(broker.connect(frame.payload));
          connected++;
          try {
            await Effect.runPromise(Stream.runForEach(stream, event => Effect.sync(() => send({ _tag: 'Chunk', requestId: frame.id, values: [event] }))), { signal: controller.signal });
            success();
          } finally { connected--; subscriptions.delete(frame.id); }
          return;
        }
        case 'previewAutomation.focusHost':
          await Effect.runPromise(broker.focusHost(frame.payload)); focusCount++; return success();
        case 'previewAutomation.respond':
          await Effect.runPromise(broker.respond(frame.payload)); responseCount++; return success();
        default: throw new Error('Unsupported fixture method');
      }
    } catch (error) {
      send({ _tag: 'Exit', requestId: frame.id, exit: { _tag: 'Failure', cause: { message: String(error) } } });
    }
  });
});
server.listen(0, '127.0.0.1', () => {
  const endpoint = `http://127.0.0.1:${server.address().port}`;
  writeFileSync(output, JSON.stringify({ endpoint, token }), { mode: 0o600 });
  console.log(JSON.stringify({ endpoint, pid: process.pid }));
});
