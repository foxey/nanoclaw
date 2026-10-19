/**
 * Discord channel adapter (v2) — uses Chat SDK bridge.
 * Self-registers on import.
 */
import { createDiscordAdapter } from '@chat-adapter/discord';

import { readEnvFile } from '../env.js';
import type { ChannelDefaults } from './adapter.js';
import { createChatSdkBridge, type ReplyContext } from './chat-sdk-bridge.js';
import { registerChannelAdapter } from './channel-registry.js';

/**
 * Dedicated bot app on a threaded platform. group threads:true matches the
 * declared supportsThreads (the skill-installed install-style knob) so
 * mention-sticky engagement stays bounded per-thread. dm.threads:false —
 * DM replies land top-level, one session per DM.
 */
const DISCORD_DEFAULTS: ChannelDefaults = {
  dm: { engageMode: 'pattern', engagePattern: '.', threads: false, unknownSenderPolicy: 'request_approval' },
  group: { engageMode: 'mention-sticky', threads: true, unknownSenderPolicy: 'request_approval' },
  mentions: 'platform',
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function extractReplyContext(raw: Record<string, any>): ReplyContext | null {
  if (!raw.referenced_message) return null;
  const reply = raw.referenced_message;
  return {
    text: reply.content || '',
    sender: reply.author?.global_name || reply.author?.username || 'Unknown',
    id: reply.id || undefined,
  };
}

/**
 * Discord message forwards carry their content in `message_snapshots`, not
 * `content` (`message_reference.type === 1` means FORWARD; 0 is a normal
 * reply). The adapter only reads `content`/`attachments`, so without this the
 * agent sees an empty message. Unwrap the snapshot back into the payload so
 * text, attachment download, and formatting all ride the existing path.
 * Note: snapshots contain no author, so the original sender is unavailable.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function unwrapForwardedSnapshot(data: Record<string, any>): void {
  if (data.message_reference?.type !== 1) return;
  const snaps = (data.message_snapshots ?? [])
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    .map((s: any) => s?.message)
    .filter(Boolean);
  if (snaps.length === 0) return;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const text = snaps
    .map((m: any) => m.content)
    .filter(Boolean)
    .join('\n');
  const label = '[Forwarded message]';
  data.content = text ? `${label}\n${text}` : data.content || label;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const fwdAttachments = snaps.flatMap((m: any) => m.attachments ?? []);
  if (fwdAttachments.length > 0) {
    data.attachments = [...(data.attachments ?? []), ...fwdAttachments];
  }
}

function unwrapForwards(adapter: ReturnType<typeof createDiscordAdapter>): void {
  const a = adapter as unknown as {
    handleForwardedMessage: (data: Record<string, unknown>, options?: unknown) => Promise<void>;
  };
  const orig = a.handleForwardedMessage.bind(adapter);
  a.handleForwardedMessage = async (data, options) => {
    unwrapForwardedSnapshot(data);
    return orig(data, options);
  };
}

/**
 * Issue C: reaction REMOVALS never reached the agent on the live Gateway path.
 * The raw `MESSAGE_REACTION_ADD` payload carries a `member.user` object, but the
 * raw `MESSAGE_REACTION_REMOVE` payload carries only `user_id` (no `user`, no
 * `member`). The vendored adapter's `handleForwardedReaction` reads
 * `data.user ?? data.member?.user` and, finding neither on a remove, logs
 * "Reaction event missing user info" and returns early — silently dropping the
 * event. (The bridge unit test passes because it calls `chat.processReaction`
 * directly, bypassing the adapter.)
 *
 * Fix, entirely in our committed source: wrap `handleForwardedReaction` so that
 * when a remove arrives without a user object we synthesize `data.user` from
 * `data.user_id` before delegating. The username is resolved via the adapter's
 * own `getUser` (same mechanism as Issue A); if that fails we still synthesize a
 * minimal `user` with the id so the event is forwarded (sender resolution then
 * falls back in the bridge). Defensive: no error escapes the wrapper.
 */
export function enrichReactionRemoves(adapter: ReturnType<typeof createDiscordAdapter>): void {
  const a = adapter as unknown as {
    handleForwardedReaction: (data: Record<string, unknown>, added: boolean, options?: unknown) => Promise<void>;
    getUser?: (userId: string) => Promise<{ userId?: string; userName?: string; fullName?: string } | null>;
  };
  const orig = a.handleForwardedReaction.bind(adapter);
  a.handleForwardedReaction = async (data, added, options) => {
    if (!data.user && !(data.member as { user?: unknown } | undefined)?.user) {
      const userId = data.user_id;
      if (typeof userId === 'string' && userId.length > 0) {
        let userName: string | undefined;
        try {
          const resolved = await a.getUser?.(userId);
          userName = resolved?.userName ?? resolved?.fullName;
        } catch {
          // Lookup failed — synthesize with id only; sender resolution falls
          // back in the bridge. Never let this throw out of the handler.
        }
        // The adapter reads userInfo.id / userInfo.username; synthesize both so
        // the early-return guard passes and the event forwards.
        data.user = { id: userId, username: userName ?? userId };
      }
    }
    return orig(data, added, options);
  };
}

/** Discord channel type ids for threads (public / private / announcement). */
const THREAD_CHANNEL_TYPES = new Set([10, 11, 12]);

/**
 * Inbound thread reactions: route a reaction placed on a message INSIDE a
 * thread to that thread's per-thread session, not the parent channel.
 *
 * The raw `MESSAGE_REACTION_ADD`/`REMOVE` Gateway payload does NOT carry
 * `channel_type` (Discord only sends `guild_id`, `channel_id`, `message_id`,
 * `user_id`/`member`, `emoji`). The vendored adapter's handleForwardedReaction
 * detects a thread SOLELY from `data.channel_type` (11/12), so with the field
 * absent it never resolves the thread: it encodes the 3-part
 * `discord:guild:<channelId>` address (where, inside a thread, `channel_id` is
 * the THREAD's own id) instead of the 4-part `discord:guild:parent:thread`
 * that normal in-thread messages carry. The reaction then looks up a message
 * in a scope that has no session, so nothing routes — the live drop. (Normal
 * messages route because the MESSAGE_CREATE payload DOES carry `data.thread` /
 * `channel_type`, so handleForwardedMessage resolves the 4-part id.)
 *
 * Fix, entirely in our committed source: when the reaction payload lacks
 * `channel_type`, fetch the channel once; if it is a thread (a thread type with
 * a `parent_id`), stamp the real `channel_type` onto the payload so the
 * adapter's existing thread-resolution branch (and its parent cache) fires and
 * builds the 4-part thread id. Main-channel reactions are unaffected: a normal
 * channel reports a non-thread type and the payload is left untouched, so the
 * 3-part channel id (which already works) is preserved. Defensive: a failed or
 * ambiguous lookup leaves the payload as-is and never throws, so an inbound
 * reaction is never worse off than before.
 */
export function enrichReactionThreadContext(adapter: ReturnType<typeof createDiscordAdapter>): void {
  const a = adapter as unknown as {
    handleForwardedReaction: (data: Record<string, unknown>, added: boolean, options?: unknown) => Promise<void>;
    discordFetch?: (path: string, method: string, body?: unknown) => Promise<Response>;
  };
  const orig = a.handleForwardedReaction.bind(adapter);
  a.handleForwardedReaction = async (data, added, options) => {
    if (data.channel_type === undefined && typeof data.channel_id === 'string' && data.channel_id.length > 0) {
      try {
        const res = await a.discordFetch?.(`/channels/${data.channel_id}`, 'GET');
        if (res?.ok) {
          const channel = (await res.json()) as { type?: number; parent_id?: string | null };
          // Only a thread (thread type WITH a parent) needs the 4-part id; a
          // plain channel keeps the 3-part address it already routes with.
          if (typeof channel.type === 'number' && THREAD_CHANNEL_TYPES.has(channel.type) && channel.parent_id) {
            data.channel_type = channel.type;
          }
        }
      } catch {
        // Lookup failed — leave the payload untouched and let the adapter fall
        // back to the channel address. Never let this throw out of the handler.
      }
    }
    return orig(data, added, options);
  };
}

registerChannelAdapter('discord', {
  factory: () => {
    const env = readEnvFile(['DISCORD_BOT_TOKEN', 'DISCORD_PUBLIC_KEY', 'DISCORD_APPLICATION_ID']);
    if (!env.DISCORD_BOT_TOKEN) return null;
    const discordAdapter = createDiscordAdapter({
      botToken: env.DISCORD_BOT_TOKEN,
      publicKey: env.DISCORD_PUBLIC_KEY,
      applicationId: env.DISCORD_APPLICATION_ID,
    });
    unwrapForwards(discordAdapter);
    enrichReactionThreadContext(discordAdapter);
    enrichReactionRemoves(discordAdapter);
    return createChatSdkBridge({
      adapter: discordAdapter,
      concurrency: 'concurrent',
      botToken: env.DISCORD_BOT_TOKEN,
      extractReplyContext,
      supportsThreads: true,
      defaults: DISCORD_DEFAULTS,
      // Discord rejects messages over 2000 chars; without this the bridge
      // would let long agent replies fail instead of splitting them.
      maxTextLength: 2000,
    });
  },
  defaults: DISCORD_DEFAULTS,
});
