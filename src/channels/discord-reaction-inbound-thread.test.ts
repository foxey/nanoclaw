/**
 * Inbound thread-reactions regression: a reaction placed on a message INSIDE a
 * thread must route to that thread's 4-part address, not the parent channel.
 *
 * This is the INBOUND path (Discord -> agent: a USER reacting), distinct from
 * the OUTBOUND addReaction path covered by discord-reaction-thread.test.ts.
 *
 * The raw Discord MESSAGE_REACTION_ADD payload does NOT carry `channel_type`,
 * and the vendored adapter's handleForwardedReaction detects a thread solely
 * from `channel_type` (11/12). With the field absent it encodes the 3-part
 * `discord:guild:<channelId>` address (inside a thread, `channel_id` is the
 * thread's own id) instead of the 4-part `discord:guild:parent:thread` that
 * normal in-thread messages carry — so the reaction looks up a message in a
 * scope with no per-thread session and nothing routes (the live production
 * drop). `enrichReactionThreadContext` (src/channels/discord.ts) fetches the
 * channel when `channel_type` is missing and, for a thread, stamps the real
 * type so the adapter builds the 4-part thread id. This test drives the real
 * adapter + a real Chat through the enrichment wrapper and asserts the
 * onReaction event targets the thread, not the parent channel.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createDiscordAdapter } from '@chat-adapter/discord';
import { Chat } from 'chat';

import { enrichReactionThreadContext } from './discord.js';
import { SqliteStateAdapter } from '../state-sqlite.js';

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

/**
 * The adapter calls chat.processReaction WITHOUT a waitUntil option, so the
 * handler runs as a detached task. Let the microtask/timer queue drain so the
 * onReaction handler has fired before we assert.
 */
function flushReaction(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

interface ReactionLike {
  added: boolean;
  messageId: string;
  threadId: string;
}

const GUILD_ID = '444444444444444444';
const PARENT_CHANNEL_ID = '222222222222222222';
const THREAD_ID = '555555555555555555';
const MESSAGE_ID = '333333333333333333';

/**
 * Wire a real adapter + Chat through the thread-context enrichment, stubbing
 * `discordFetch` so the channel lookup resolves to the given channel shape with
 * no network. Captures each onReaction event's address.
 */
async function buildWiredAdapter(channel: { type?: number; parent_id?: string | null }) {
  const adapter = createDiscordAdapter({
    botToken: 'test-token',
    publicKey: 'ff'.repeat(32),
    applicationId: '000000000000000001',
  });
  const discordFetch = vi.fn(async (path: string) => {
    if (path === `/channels/${THREAD_ID}` || path === `/channels/${PARENT_CHANNEL_ID}`) {
      return new Response(JSON.stringify(channel), { status: 200 });
    }
    return new Response('{}', { status: 404 });
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (adapter as any).discordFetch = discordFetch;
  enrichReactionThreadContext(adapter);

  const captured: ReactionLike[] = [];
  const chat = new Chat({
    adapters: { discord: adapter },
    userName: 'NanoClaw',
    state: new SqliteStateAdapter(),
    logger: 'silent',
  });
  chat.onReaction((event) => {
    captured.push({ added: event.added, messageId: event.messageId, threadId: event.thread.id });
  });
  await chat.initialize();
  return { adapter, captured, discordFetch };
}

/**
 * Raw MESSAGE_REACTION_ADD inside a thread: `channel_id` is the THREAD's own
 * id, `channel_type` absent (Discord does not send it on reaction events).
 */
function threadReactionPayload() {
  return {
    user_id: '111111111111111111',
    channel_id: THREAD_ID,
    message_id: MESSAGE_ID,
    guild_id: GUILD_ID,
    emoji: { name: '👍', id: null },
    member: { user: { id: '111111111111111111', username: 'foxey8145', global_name: 'foxey' } },
  };
}

describe('enrichReactionThreadContext (inbound thread reactions)', () => {
  it('routes an in-thread reaction to the 4-part thread address, not the parent channel', async () => {
    const { adapter, captured, discordFetch } = await buildWiredAdapter({
      type: 11, // GuildPublicThread
      parent_id: PARENT_CHANNEL_ID,
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(threadReactionPayload(), true);
    await flushReaction();

    expect(captured).toHaveLength(1);
    expect(captured[0].added).toBe(true);
    expect(captured[0].messageId).toBe(MESSAGE_ID);
    // 4-part thread address: discord:guild:parent:thread — NOT the 3-part
    // discord:guild:<threadId> the adapter would emit without the fix.
    expect(captured[0].threadId).toBe(`discord:${GUILD_ID}:${PARENT_CHANNEL_ID}:${THREAD_ID}`);
    expect(discordFetch).toHaveBeenCalledWith(`/channels/${THREAD_ID}`, 'GET');
  });

  it('leaves a main-channel reaction on the 3-part channel address (no regression)', async () => {
    // Fetch reports a plain text channel (type 0, no parent) — not a thread.
    const { adapter, captured } = await buildWiredAdapter({ type: 0, parent_id: null });

    const payload = {
      ...threadReactionPayload(),
      channel_id: PARENT_CHANNEL_ID, // reaction in the parent channel, not a thread
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(payload, true);
    await flushReaction();

    expect(captured).toHaveLength(1);
    // 3-part channel address — unchanged main-channel behavior.
    expect(captured[0].threadId).toBe(`discord:${GUILD_ID}:${PARENT_CHANNEL_ID}`);
  });

  it('leaves the payload untouched when the channel lookup fails', async () => {
    const adapter = createDiscordAdapter({
      botToken: 'test-token',
      publicKey: 'ff'.repeat(32),
      applicationId: '000000000000000001',
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (adapter as any).discordFetch = vi.fn(async () => {
      throw new Error('network down');
    });
    enrichReactionThreadContext(adapter);

    const captured: ReactionLike[] = [];
    const chat = new Chat({
      adapters: { discord: adapter },
      userName: 'NanoClaw',
      state: new SqliteStateAdapter(),
      logger: 'silent',
    });
    chat.onReaction((event) => {
      captured.push({ added: event.added, messageId: event.messageId, threadId: event.thread.id });
    });
    await chat.initialize();

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(threadReactionPayload(), true);
    await flushReaction();

    // Still forwarded (never dropped); falls back to the 3-part address.
    expect(captured).toHaveLength(1);
    expect(captured[0].threadId).toBe(`discord:${GUILD_ID}:${THREAD_ID}`);
  });
});
