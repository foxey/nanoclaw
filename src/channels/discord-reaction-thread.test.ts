/**
 * In-thread emoji reaction regression: the user reports reactions work in the
 * main channel but not inside a thread.
 *
 * The host-side stub tests (chat-sdk-bridge.test.ts) prove the bridge forwards
 * the row's thread id verbatim to adapter.addReaction, and the MCP-layer tests
 * (mcp-tools/core.test.ts) prove the reaction row carries the same routing
 * tuple as an edit. What those stub tests DON'T exercise is the vendored
 * @chat-adapter/discord adapter's own resolution: addReaction/editMessage both
 * call decodeThreadId(tid) and target `discordThreadId || channelId`. That is
 * the layer where an in-thread reaction would "target the wrong channel" if the
 * tid were mis-decoded.
 *
 * This test drives the REAL adapter addReaction (and editMessage for parity)
 * against a mocked fetch, and asserts:
 *   1. an in-thread tid resolves the Discord reaction PUT to the THREAD channel,
 *      not the parent channel, for BOTH id encodings a thread message can carry
 *      (4-part discord:guild:channel:thread, and the 3-part discord:guild:thread
 *      form where msg.channel_id is itself the thread);
 *   2. a main-channel tid resolves to the channel (no regression);
 *   3. reaction and edit resolve to the IDENTICAL target channel for the same
 *      in-thread tid — the symmetry the working edit path relies on.
 */
import { afterEach, describe, expect, it, vi } from 'vitest';

import { createDiscordAdapter } from '@chat-adapter/discord';

afterEach(() => {
  vi.restoreAllMocks();
});

function buildAdapter() {
  return createDiscordAdapter({
    botToken: 'test-token',
    publicKey: 'ff'.repeat(32),
    applicationId: '000000000000000001',
  });
}

/**
 * Capture every Discord REST path the adapter hits. Discord's reaction PUT and
 * message PATCH return 204/200 with (for PATCH) a JSON body; return an ok
 * Response so discordFetch does not throw. Paths are captured as the segment
 * from `/channels/...` onward so the test is independent of the `/api/vN`
 * base-url prefix the adapter prepends.
 */
function captureFetch(): { paths: string[] } {
  const paths: string[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: Parameters<typeof fetch>[0]) => {
    const url = typeof input === 'string' ? input : input.toString();
    const { pathname } = new URL(url);
    const idx = pathname.indexOf('/channels/');
    paths.push(idx === -1 ? pathname : pathname.slice(idx));
    return new Response(JSON.stringify({ id: 'result-id' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  });
  return { paths };
}

/** The Discord channel segment a target path resolves to: /channels/<id>/... */
function targetChannel(path: string): string {
  return path.split('/')[2];
}

describe('Discord adapter — in-thread reaction targets the thread channel', () => {
  it('a 4-part thread tid resolves the reaction PUT to the thread, not the parent channel', async () => {
    const adapter = buildAdapter();
    const { paths } = captureFetch();

    // discord:guild:channel:thread — the thread id a message received inside a
    // thread carries (parent channel + thread segment).
    await adapter.addReaction('discord:444:555:666', '333', 'thumbs_up');

    expect(paths).toHaveLength(1);
    // The reacted-to message lives in thread 666, NOT parent channel 555.
    expect(paths[0]).toBe('/channels/666/messages/333/reactions/%F0%9F%91%8D/@me');
  });

  it('a 3-part thread tid (msg.channel_id is the thread) resolves to that thread channel', async () => {
    const adapter = buildAdapter();
    const { paths } = captureFetch();

    // discord:guild:thread — the encoding a thread message carries when the
    // adapter has only msg.channel_id (the thread itself) and no separate
    // parent segment. channelId === the thread, so the reaction still lands
    // in the thread.
    await adapter.addReaction('discord:444:666', '333', 'thumbs_up');

    expect(paths).toHaveLength(1);
    expect(paths[0]).toBe('/channels/666/messages/333/reactions/%F0%9F%91%8D/@me');
  });

  it('a main-channel tid resolves the reaction PUT to the channel (no regression)', async () => {
    const adapter = buildAdapter();
    const { paths } = captureFetch();

    await adapter.addReaction('discord:444:555', '333', 'thumbs_up');

    expect(paths).toHaveLength(1);
    expect(paths[0]).toBe('/channels/555/messages/333/reactions/%F0%9F%91%8D/@me');
  });

  it('reaction and edit resolve to the IDENTICAL target channel for the same in-thread tid', async () => {
    const tid = 'discord:444:555:666';

    const reactionAdapter = buildAdapter();
    const reactionCapture = captureFetch();
    await reactionAdapter.addReaction(tid, '333', 'thumbs_up');
    vi.restoreAllMocks();

    const editAdapter = buildAdapter();
    const editCapture = captureFetch();
    await editAdapter.editMessage(tid, '333', { markdown: 'edited' });

    const reactionChannel = targetChannel(reactionCapture.paths[0]);
    const editChannel = targetChannel(editCapture.paths[0]);
    // Both operations must target the same thread channel (666) — the symmetry
    // the working edit-in-thread path relies on.
    expect(reactionChannel).toBe('666');
    expect(editChannel).toBe('666');
    expect(reactionChannel).toBe(editChannel);
  });
});
