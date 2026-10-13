/**
 * Issue C regression: a live reaction REMOVE must reach onReaction.
 *
 * The raw Discord MESSAGE_REACTION_REMOVE payload carries only `user_id`
 * (no `user`, no `member`), so the vendored adapter's handleForwardedReaction
 * early-returns ("Reaction event missing user info") and the removal is
 * silently dropped. `enrichReactionRemoves` (src/channels/discord.ts)
 * synthesizes `data.user` from `data.user_id` before the adapter sees it so
 * the event forwards. This test drives the real adapter + a real Chat through
 * the enrichment wrapper and asserts an onReaction event with added:false is
 * produced rather than dropped.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { createDiscordAdapter } from '@chat-adapter/discord';
import { Chat } from 'chat';

import { enrichReactionRemoves } from './discord.js';
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
  user?: { userId?: string; userName?: string; fullName?: string };
}

async function buildWiredAdapter(getUser?: (userId: string) => Promise<unknown>) {
  const adapter = createDiscordAdapter({
    botToken: 'test-token',
    publicKey: 'ff'.repeat(32),
    applicationId: '000000000000000001',
  });
  // Avoid any network: stub getUser (used by the enrichment wrapper).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (adapter as any).getUser = getUser ?? (async () => null);
  enrichReactionRemoves(adapter);

  const captured: ReactionLike[] = [];
  const chat = new Chat({
    adapters: { discord: adapter },
    userName: 'NanoClaw',
    state: new SqliteStateAdapter(),
    logger: 'silent',
  });
  chat.onReaction((event) => {
    captured.push({ added: event.added, messageId: event.messageId, user: event.user });
  });
  await chat.initialize();
  return { adapter, captured };
}

/** Raw MESSAGE_REACTION_REMOVE: only user_id, no user/member. */
function removePayload() {
  return {
    user_id: '111111111111111111',
    channel_id: '222222222222222222',
    message_id: '333333333333333333',
    guild_id: '444444444444444444',
    emoji: { name: '👍', id: null },
  };
}

describe('enrichReactionRemoves (Issue C)', () => {
  it('forwards a reaction remove that lacks user/member instead of dropping it', async () => {
    const { adapter, captured } = await buildWiredAdapter(async () => ({
      userId: '111111111111111111',
      userName: 'foxey8145',
      fullName: 'foxey',
      isBot: false,
    }));

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(removePayload(), false);
    await flushReaction();

    expect(captured).toHaveLength(1);
    expect(captured[0].added).toBe(false);
    expect(captured[0].messageId).toBe('333333333333333333');
    expect(captured[0].user?.userId).toBe('111111111111111111');
  });

  it('still forwards the remove when getUser fails (synthesizes id-only user)', async () => {
    const { adapter, captured } = await buildWiredAdapter(async () => {
      throw new Error('network down');
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(removePayload(), false);
    await flushReaction();

    expect(captured).toHaveLength(1);
    expect(captured[0].added).toBe(false);
    expect(captured[0].user?.userId).toBe('111111111111111111');
  });

  it('does not disturb a reaction add that already carries member.user', async () => {
    const getUser = vi.fn(async () => null);
    const { adapter, captured } = await buildWiredAdapter(getUser);

    const addPayload = {
      ...removePayload(),
      member: { user: { id: '111111111111111111', username: 'foxey8145', global_name: 'foxey' } },
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (adapter as any).handleForwardedReaction(addPayload, true);
    await flushReaction();

    expect(captured).toHaveLength(1);
    expect(captured[0].added).toBe(true);
    // getUser must NOT be consulted when a user object is already present.
    expect(getUser).not.toHaveBeenCalled();
  });
});
