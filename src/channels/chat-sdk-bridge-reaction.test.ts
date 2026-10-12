/**
 * Bridge reaction dispatch: chat.onReaction events registered in setup()
 * flow through the inbound pipeline. Both adds and removes are forwarded; the
 * synthetic message id encodes which so add/remove on the same target don't
 * collide.
 *
 * Same test strategy as chat-sdk-bridge-membership.test.ts — real Chat
 * instance via the mocked registerWebhookAdapter, processReaction through
 * dispatch() with waitUntil.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Adapter, Chat } from 'chat';

import { createChatSdkBridge } from './chat-sdk-bridge.js';
import type { InboundMessage } from './adapter.js';

vi.mock('../webhook-server.js', () => ({
  registerWebhookAdapter: vi.fn(),
}));

import { registerWebhookAdapter } from '../webhook-server.js';

function stubAdapter(name: string, partial: Partial<Adapter> = {}): Adapter {
  return {
    name,
    initialize: async () => {},
    channelIdFromThreadId: (threadId: string) => threadId.split(':').slice(0, 2).join(':'),
    ...partial,
  } as unknown as Adapter;
}

/** Drive a Chat process* dispatcher and await its internal task. */
async function dispatch(fire: (options: { waitUntil: (p: Promise<unknown>) => void }) => void): Promise<void> {
  let task: Promise<unknown> | undefined;
  fire({
    waitUntil: (p) => {
      task = p;
    },
  });
  await task;
}

/** The Chat instance setup() registered on the (mocked) webhook server. */
function lastRegisteredChat(): Chat {
  const calls = vi.mocked(registerWebhookAdapter).mock.calls;
  return calls[calls.length - 1][0] as Chat;
}

beforeEach(async () => {
  const { initTestDb } = await import('../db/connection.js');
  const { runMigrations } = await import('../db/migrations/index.js');
  await runMigrations(await initTestDb());
});

afterEach(async () => {
  const { closeDb } = await import('../db/connection.js');
  await closeDb();
  vi.restoreAllMocks();
});

function mockEmojiValue(name: string) {
  return { name, toString: () => `:${name}:`, toJSON: () => `:${name}:` };
}

const defaultUser = {
  userId: 'U0REACTOR',
  userName: 'reactor',
  fullName: 'Reacting User',
  isBot: false as const,
  isMe: false as const,
};

describe('chat.onReaction dispatch', () => {
  it('reaction-add dispatches onInbound with correct channelId, threadId, and content', async () => {
    const captured: { channelId: string; threadId: string | null; message: InboundMessage }[] = [];
    const adapter = stubAdapter('test-platform');
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup({
      onInbound: (channelId, threadId, message) => {
        captured.push({ channelId, threadId, message });
      },
      onInboundEvent: () => {},
      onMetadata: () => {},
      onAction: () => {},
    });

    const chat = (bridge as unknown as { _chat: Chat })._chat;

    await dispatch((options) =>
      chat.processReaction(
        {
          added: true,
          emoji: mockEmojiValue('thumbs_up'),
          rawEmoji: '👍',
          messageId: 'MSG123',
          threadId: 'test-platform:CH1:T1',
          user: defaultUser,
          adapter,
          raw: {},
        },
        options,
      ),
    );

    expect(captured).toHaveLength(1);
    const { channelId, threadId, message } = captured[0];
    expect(channelId).toBe(adapter.channelIdFromThreadId('test-platform:CH1:T1'));
    expect(threadId).toBe('test-platform:CH1:T1');
    expect(message.kind).toBe('chat-sdk');
    const content = message.content as Record<string, unknown>;
    expect(content.text).toBe('');
    expect(content.reaction).toEqual({
      emoji: '👍',
      messageId: 'MSG123',
      added: true,
    });
    expect(content.senderId).toBe('U0REACTOR');
    expect(content.sender).toBe('Reacting User');
    expect(content.senderName).toBe('Reacting User');

    await bridge.teardown();
  });

  it('reaction-remove (added:false) dispatches onInbound with added:false content', async () => {
    const captured: { channelId: string; threadId: string | null; message: InboundMessage }[] = [];
    const adapter = stubAdapter('test-platform');
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup({
      onInbound: (channelId, threadId, message) => {
        captured.push({ channelId, threadId, message });
      },
      onInboundEvent: () => {},
      onMetadata: () => {},
      onAction: () => {},
    });

    const chat = (bridge as unknown as { _chat: Chat })._chat;

    await dispatch((options) =>
      chat.processReaction(
        {
          added: false,
          emoji: mockEmojiValue('thumbs_up'),
          rawEmoji: '👍',
          messageId: 'MSG456',
          threadId: 'test-platform:CH1:T1',
          user: defaultUser,
          adapter,
          raw: {},
        },
        options,
      ),
    );

    expect(captured).toHaveLength(1);
    const content = captured[0].message.content as Record<string, unknown>;
    expect(content.reaction).toEqual({
      emoji: '👍',
      messageId: 'MSG456',
      added: false,
    });

    await bridge.teardown();
  });

  it('inbound message has isMention:false and isGroup:true', async () => {
    let receivedMessage: InboundMessage | undefined;
    const adapter = stubAdapter('test-platform');
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup({
      onInbound: (_channelId, _threadId, message) => {
        receivedMessage = message;
      },
      onInboundEvent: () => {},
      onMetadata: () => {},
      onAction: () => {},
    });

    const chat = (bridge as unknown as { _chat: Chat })._chat;

    await dispatch((options) =>
      chat.processReaction(
        {
          added: true,
          emoji: mockEmojiValue('heart'),
          rawEmoji: '❤️',
          messageId: 'MSG789',
          threadId: 'test-platform:CH2:T2',
          user: defaultUser,
          adapter,
          raw: {},
        },
        options,
      ),
    );

    expect(receivedMessage).toBeDefined();
    expect(receivedMessage!.isMention).toBe(false);
    expect(receivedMessage!.isGroup).toBe(true);

    await bridge.teardown();
  });

  it('synthesized id encodes add/remove so the same target does not collide', async () => {
    const ids: string[] = [];
    const adapter = stubAdapter('test-platform');
    const bridge = createChatSdkBridge({ adapter, supportsThreads: true });
    await bridge.setup({
      onInbound: (_channelId, _threadId, message) => {
        ids.push(message.id);
      },
      onInboundEvent: () => {},
      onMetadata: () => {},
      onAction: () => {},
    });

    const chat = (bridge as unknown as { _chat: Chat })._chat;

    const fire = (added: boolean) =>
      dispatch((options) =>
        chat.processReaction(
          {
            added,
            emoji: mockEmojiValue('rocket'),
            rawEmoji: '🚀',
            messageId: 'MSG_ABC',
            threadId: 'test-platform:CH3:T3',
            user: defaultUser,
            adapter,
            raw: {},
          },
          options,
        ),
      );

    await fire(true);
    await fire(false);

    expect(ids).toHaveLength(2);
    expect(ids[0]).toMatch(/^reaction-add-MSG_ABC-U0REACTOR-\d+$/);
    expect(ids[1]).toMatch(/^reaction-remove-MSG_ABC-U0REACTOR-\d+$/);

    await bridge.teardown();
  });
});
