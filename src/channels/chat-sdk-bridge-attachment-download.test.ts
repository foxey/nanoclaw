/**
 * Tests for inbound attachment download in the chat-sdk bridge.
 *
 * Discord's adapter builds inbound attachments as { url, ... } with no
 * fetchData(), so the bridge must fall back to fetching `att.url` and populate
 * `entry.data` (base64) — the same field the fetchData path feeds and the field
 * the downstream inbox staging reads. These tests drive the REAL bridge path: a
 * stub adapter captures the ChatInstance at initialize and pushes duck-typed
 * messages via chat.processMessage(...), so the SDK's own dispatch delivers them
 * to the bridge handlers and messageToInbound runs for real.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Adapter } from 'chat';
import type { ChannelSetup, InboundMessage } from './adapter.js';
import { createChatSdkBridge } from './chat-sdk-bridge.js';

vi.mock('../webhook-server.js', () => ({
  registerWebhookAdapter: vi.fn(),
}));
vi.mock('../log.js', () => ({
  log: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn(), fatal: vi.fn() },
}));

/** Minimal ChatInstance surface the test drives. */
interface ChatDriver {
  processMessage(adapter: Adapter, threadId: string, message: unknown): Promise<void>;
}

/**
 * Stub adapter that captures the ChatInstance at initialize so tests can push
 * messages through the SDK's real dispatch into the bridge handlers.
 */
function makeStubAdapter(name: string): { adapter: Adapter; chat: () => ChatDriver } {
  let captured: ChatDriver | null = null;
  const adapter = {
    name,
    initialize: async (chat: ChatDriver) => {
      captured = chat;
    },
    channelIdFromThreadId: (threadId: string) => threadId.split(':').slice(0, 2).join(':'),
  } as unknown as Adapter;
  return {
    adapter,
    chat: () => {
      if (!captured) throw new Error('adapter not initialized — call bridge.setup() first');
      return captured;
    },
  };
}

let nextMessageId = 0;

/** Duck-typed Chat SDK message carrying the given attachments. */
function makeMessage(attachments: Array<Record<string, unknown>>): Record<string, unknown> {
  const id = `msg-${++nextMessageId}`;
  const payload = {
    id,
    text: 'see attachment',
    author: { userId: 'U123', userName: 'human', fullName: 'A Human', isBot: false, isMe: false },
    attachments,
  };
  return {
    ...payload,
    isMention: false,
    metadata: { dateSent: new Date('2026-01-01T00:00:00.000Z') },
    raw: undefined,
    // toJSON drops fetchData (a function); the bridge enriches BEFORE this.
    toJSON: () => ({
      ...payload,
      attachments: attachments.map((a) => {
        const { fetchData: _drop, ...rest } = a;
        return rest;
      }),
    }),
  };
}

interface InboundCall {
  platformId: string;
  threadId: string | null;
  message: InboundMessage;
}
function makeHostConfig(): { hostConfig: ChannelSetup; calls: InboundCall[] } {
  const calls: InboundCall[] = [];
  const hostConfig: ChannelSetup = {
    onInbound: (platformId, threadId, message) => {
      calls.push({ platformId, threadId, message });
    },
    onInboundEvent: () => {},
    onMetadata: () => {},
    onAction: () => {},
  };
  return { hostConfig, calls };
}

/** Pull the first attachment of the first inbound call. */
function firstAttachment(calls: InboundCall[]): Record<string, unknown> {
  expect(calls).toHaveLength(1);
  const content = calls[0].message.content as Record<string, unknown>;
  const atts = content.attachments as Array<Record<string, unknown>>;
  return atts[0];
}

const SIGNED_URL = 'https://cdn.example/discord/message.txt?sig=secret';

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(async () => {
  const { initTestDb } = await import('../db/connection.js');
  const { runMigrations } = await import('../db/migrations/index.js');
  await runMigrations(await initTestDb());
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});
afterEach(async () => {
  vi.unstubAllGlobals();
  const { closeDb } = await import('../db/connection.js');
  await closeDb();
});

describe('chat-sdk bridge attachment download', () => {
  it('fetches att.url and populates entry.data when fetchData is absent', async () => {
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      arrayBuffer: async () => new TextEncoder().encode('hello').buffer,
    });
    const { adapter, chat } = makeStubAdapter('discord');
    const { hostConfig, calls } = makeHostConfig();
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup(hostConfig);

    await chat().processMessage(
      adapter,
      'discord:C1:T1',
      makeMessage([{ type: 'file', name: 'message.txt', mimeType: 'text/plain', size: 4271, url: SIGNED_URL }]),
    );

    expect(fetchMock).toHaveBeenCalledWith(SIGNED_URL);
    const att = firstAttachment(calls);
    expect(att.data).toBe(Buffer.from('hello').toString('base64'));
    await bridge.teardown();
  });

  it('prefers fetchData and does not call fetch when fetchData is present', async () => {
    const { adapter, chat } = makeStubAdapter('discord');
    const { hostConfig, calls } = makeHostConfig();
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup(hostConfig);

    await chat().processMessage(
      adapter,
      'discord:C1:T2',
      makeMessage([
        {
          type: 'file',
          name: 'message.txt',
          mimeType: 'text/plain',
          size: 12,
          fetchData: async () => Buffer.from('viaFetchData'),
        },
      ]),
    );

    expect(fetchMock).not.toHaveBeenCalled();
    const att = firstAttachment(calls);
    expect(att.data).toBe(Buffer.from('viaFetchData').toString('base64'));
    await bridge.teardown();
  });

  it('does not break the message and leaves data unset when the url fetch fails, logging host+status only', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 403, arrayBuffer: async () => new ArrayBuffer(0) });
    const { log } = (await import('../log.js')) as unknown as { log: { warn: ReturnType<typeof vi.fn> } };
    const { adapter, chat } = makeStubAdapter('discord');
    const { hostConfig, calls } = makeHostConfig();
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup(hostConfig);

    await chat().processMessage(
      adapter,
      'discord:C1:T3',
      makeMessage([{ type: 'file', name: 'message.txt', mimeType: 'text/plain', size: 4271, url: SIGNED_URL }]),
    );

    const att = firstAttachment(calls);
    expect(att.data).toBeUndefined();
    expect(log.warn).toHaveBeenCalled();
    // The signed url must never be logged — only host + status.
    for (const call of log.warn.mock.calls) {
      const serialized = JSON.stringify(call);
      expect(serialized).not.toContain('sig=secret');
      expect(serialized).not.toContain(SIGNED_URL);
    }
    const warnCall = log.warn.mock.calls.find((c) => c[0] === 'Failed to download attachment via url');
    expect(warnCall).toBeDefined();
    expect((warnCall?.[1] as Record<string, unknown>).host).toBe('cdn.example');
    expect((warnCall?.[1] as Record<string, unknown>).status).toBe(403);
    await bridge.teardown();
  });
});
