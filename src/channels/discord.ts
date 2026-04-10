import {
  Client,
  Events,
  GatewayIntentBits,
  Message,
  MessageReaction,
  PartialMessageReaction,
  PartialUser,
  Partials,
  TextChannel,
  User,
} from 'discord.js';

import { ASSISTANT_NAME, TRIGGER_PATTERN } from '../config.js';
import { readEnvFile } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

/**
 * Emoji reactions translated to short text tokens and forwarded to the agent
 * as a reply to the reacted-to message. The agent decides what to do with the
 * token in context (e.g. "1" → "post 1" in the GitHub digest workflow).
 */
const EMOJI_REACTIONS: Record<string, string> = {
  // ── Thumbs up (all skin tones) ──────────────────────────────────────────
  '👍': 'yes',
  '👍🏻': 'yes',
  '👍🏼': 'yes',
  '👍🏽': 'yes',
  '👍🏾': 'yes',
  '👍🏿': 'yes',
  // ── Thumbs down (all skin tones) ────────────────────────────────────────
  '👎': 'no',
  '👎🏻': 'no',
  '👎🏼': 'no',
  '👎🏽': 'no',
  '👎🏾': 'no',
  '👎🏿': 'no',
  // ── Check / cross ────────────────────────────────────────────────────────
  '✅': 'yes',
  '❌': 'no',
  // ── Number keycaps 0–9 ───────────────────────────────────────────────────
  '0️⃣': '0',
  '1️⃣': '1',
  '2️⃣': '2',
  '3️⃣': '3',
  '4️⃣': '4',
  '5️⃣': '5',
  '6️⃣': '6',
  '7️⃣': '7',
  '8️⃣': '8',
  '9️⃣': '9',
  // ── Positive / celebratory ───────────────────────────────────────────────
  '🎉': 'celebrate',
  '🥳': 'celebrate',
  '🤩': 'amazing',
  '🥰': 'love',
  '😍': 'love',
  '😁': 'great',
  '😄': 'great',
  '😊': 'great',
  '☺️': 'great',
  // ── Hands (all skin tones) ───────────────────────────────────────────────
  '🙌': 'great',
  '🙌🏻': 'great',
  '🙌🏼': 'great',
  '🙌🏽': 'great',
  '🙌🏾': 'great',
  '🙌🏿': 'great',
  '🙏': 'thanks',
  '🙏🏻': 'thanks',
  '🙏🏼': 'thanks',
  '🙏🏽': 'thanks',
  '🙏🏾': 'thanks',
  '🙏🏿': 'thanks',
  // ── Shrug — neutral + man + woman, all skin tones ────────────────────────
  '🤷': 'shrug',
  '🤷🏻': 'shrug',
  '🤷🏼': 'shrug',
  '🤷🏽': 'shrug',
  '🤷🏾': 'shrug',
  '🤷🏿': 'shrug',
  '🤷‍♂️': 'shrug',
  '🤷🏻‍♂️': 'shrug',
  '🤷🏼‍♂️': 'shrug',
  '🤷🏽‍♂️': 'shrug',
  '🤷🏾‍♂️': 'shrug',
  '🤷🏿‍♂️': 'shrug',
  '🤷‍♀️': 'shrug',
  '🤷🏻‍♀️': 'shrug',
  '🤷🏼‍♀️': 'shrug',
  '🤷🏽‍♀️': 'shrug',
  '🤷🏾‍♀️': 'shrug',
  '🤷🏿‍♀️': 'shrug',
  // ── Neutral / mild ───────────────────────────────────────────────────────
  '🙂': 'ok',
  '🥲': 'bittersweet',
  '😉': 'wink',
  '🤔': 'thinking',
  '🤨': 'hmm',
  '😳': 'wow',
  '😕': 'confused',
  // ── Negative / sad ───────────────────────────────────────────────────────
  '😞': 'sad',
  '😢': 'sad',
  '☹️': 'sad',
  '🙁': 'sad',
  '😠': 'angry',
  '😡': 'angry',
  // ── Funny / surprised ────────────────────────────────────────────────────
  '😂': 'lol',
  '🤣': 'lol',
  '😬': 'yikes',
  '🙀': 'omg',
  '😱': 'omg',
};

export interface DiscordChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
}

export class DiscordChannel implements Channel {
  name = 'discord';

  private client: Client | null = null;
  private opts: DiscordChannelOpts;
  private botToken: string;

  constructor(botToken: string, opts: DiscordChannelOpts) {
    this.botToken = botToken;
    this.opts = opts;
  }

  async connect(): Promise<void> {
    this.client = new Client({
      intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
        GatewayIntentBits.DirectMessages,
        GatewayIntentBits.GuildMessageReactions,
      ],
      partials: [
        Partials.Channel,
        Partials.Message,
        Partials.Reaction,
        Partials.User,
      ],
    });

    // discord.js v14 silently drops MessageCreate for DM channels: partial DM channels
    // lack a type field so isTextBased() returns false. Handle DMs via the raw gateway
    // event instead, which always fires regardless of channel cache state.
    this.client.on(
      'raw',
      async (event: { t: string; d: Record<string, unknown> }) => {
        if (event.t !== 'MESSAGE_CREATE') return;
        const data = event.d;
        if (data.guild_id) return; // guild messages are handled by MessageCreate

        const author = data.author as {
          id: string;
          username: string;
          global_name?: string;
          bot?: boolean;
        } | null;
        if (!author || author.bot) return;

        const channelId = data.channel_id as string;
        const chatJid = `dc:${channelId}`;
        const content = (data.content as string) || '';
        const timestamp = data.timestamp as string;
        const senderName = author.global_name || author.username;
        const sender = author.id;
        const msgId = data.id as string;

        logger.info({ chatJid }, 'Discord DM received');

        this.opts.onChatMetadata(
          chatJid,
          new Date(timestamp).toISOString(),
          senderName,
          'discord',
          false,
        );

        const group = this.opts.registeredGroups()[chatJid];
        if (!group) {
          logger.debug(
            { chatJid, senderName },
            'DM from unregistered Discord channel',
          );
          return;
        }

        this.opts.onMessage(chatJid, {
          id: msgId,
          chat_jid: chatJid,
          sender,
          sender_name: senderName,
          content,
          timestamp: new Date(timestamp).toISOString(),
          is_from_me: false,
        });

        logger.info({ chatJid, sender: senderName }, 'Discord DM stored');
      },
    );

    this.client.on(Events.MessageCreate, async (message: Message) => {
      // Ignore bot messages (including own)
      if (!message.author || message.author.bot) return;
      // DMs are handled by the raw event handler above
      if (!message.guild) return;
      const channelId = message.channelId;
      // If the message is in a thread, route it to the parent channel's group
      const isThread = message.channel.isThread();
      const threadParentId = isThread ? message.channel.parentId : null;
      const groupChannelId = threadParentId ?? channelId;
      const chatJid = `dc:${groupChannelId}`;
      let content = message.content;
      const timestamp = message.createdAt.toISOString();
      const senderName =
        message.member?.displayName ||
        message.author.displayName ||
        message.author.username;
      const sender = message.author.id;
      const msgId = message.id;

      // Determine chat name (use parent channel name when inside a thread)
      let chatName: string;
      if (message.guild) {
        const displayChannel = isThread
          ? message.channel.parent
          : (message.channel as TextChannel);
        chatName = `${message.guild.name} #${displayChannel?.name ?? 'unknown'}`;
      } else {
        chatName = senderName;
      }

      // Translate Discord @bot mentions into TRIGGER_PATTERN format.
      // Discord mentions look like <@botUserId> — these won't match
      // TRIGGER_PATTERN (e.g., ^@Andy\b), so we prepend the trigger
      // when the bot is @mentioned.
      if (this.client?.user) {
        const botId = this.client.user.id;
        const isBotMentioned =
          message.mentions.users.has(botId) ||
          content.includes(`<@${botId}>`) ||
          content.includes(`<@!${botId}>`);

        if (isBotMentioned) {
          // Strip the <@botId> mention to avoid visual clutter
          content = content
            .replace(new RegExp(`<@!?${botId}>`, 'g'), '')
            .trim();
          // Prepend trigger if not already present
          if (!TRIGGER_PATTERN.test(content)) {
            content = `@${ASSISTANT_NAME} ${content}`;
          }
        }
      }

      // Handle attachments — store placeholders so the agent knows something was sent
      if (message.attachments.size > 0) {
        const attachmentDescriptions = [...message.attachments.values()].map(
          (att) => {
            const contentType = att.contentType || '';
            if (contentType.startsWith('image/')) {
              return `[Image: ${att.name || 'image'}]`;
            } else if (contentType.startsWith('video/')) {
              return `[Video: ${att.name || 'video'}]`;
            } else if (contentType.startsWith('audio/')) {
              return `[Audio: ${att.name || 'audio'}]`;
            } else {
              return `[File: ${att.name || 'file'}]`;
            }
          },
        );
        if (content) {
          content = `${content}\n${attachmentDescriptions.join('\n')}`;
        } else {
          content = attachmentDescriptions.join('\n');
        }
      }

      // Handle reply context — include who the user is replying to
      if (message.reference?.messageId) {
        try {
          const repliedTo = await message.channel.messages.fetch(
            message.reference.messageId,
          );
          const replyAuthor =
            repliedTo.member?.displayName ||
            repliedTo.author.displayName ||
            repliedTo.author.username;
          content = `[Reply to ${replyAuthor}] ${content}`;
        } catch {
          // Referenced message may have been deleted
        }
      }

      // Store chat metadata for discovery
      const isGroup = message.guild !== null;
      this.opts.onChatMetadata(
        chatJid,
        timestamp,
        chatName,
        'discord',
        isGroup,
      );

      // Only deliver full message for registered groups
      const group = this.opts.registeredGroups()[chatJid];
      if (!group) {
        logger.debug(
          { chatJid, chatName },
          'Message from unregistered Discord channel',
        );
        return;
      }

      // Deliver message — startMessageLoop() will pick it up
      this.opts.onMessage(chatJid, {
        id: msgId,
        chat_jid: chatJid,
        sender,
        sender_name: senderName,
        content,
        timestamp,
        is_from_me: false,
        ...(isThread ? { thread_id: `dc:${channelId}` } : {}),
      });

      logger.info(
        { chatJid, chatName, sender: senderName },
        'Discord message stored',
      );
    });

    // Handle emoji reactions — translate approved reactions on bot messages
    // into synthetic approval messages so agents can respond without typed replies.
    this.client.on(
      Events.MessageReactionAdd,
      async (
        reaction: MessageReaction | PartialMessageReaction,
        user: User | PartialUser,
      ) => {
        // Ignore reactions from bots (including self)
        if (user.bot) return;

        // Fetch partial reaction if needed
        if (reaction.partial) {
          try {
            reaction = await reaction.fetch();
          } catch (err) {
            logger.debug({ err }, 'Failed to fetch partial reaction');
            return;
          }
        }

        const message = reaction.message.partial
          ? await reaction.message.fetch().catch((err) => {
              logger.debug({ err }, 'Failed to fetch partial reaction message');
              return null;
            })
          : reaction.message;

        if (!message) return;

        // Only handle reactions on the bot's own messages
        if (!message.author?.bot) return;
        if (message.author.id !== this.client?.user?.id) return;

        const channelId = message.channelId;
        const chatJid = `dc:${channelId}`;

        const group = this.opts.registeredGroups()[chatJid];
        if (!group) return;

        // Map emoji to approval text — ignore unrecognised reactions
        const emojiName = reaction.emoji.name ?? '';
        const approvalText = EMOJI_REACTIONS[emojiName];
        if (!approvalText) return;

        // Fetch full user if partial
        const fullUser: User = user.partial
          ? await (user as PartialUser).fetch().catch((err) => {
              logger.debug({ err }, 'Failed to fetch partial reaction user');
              return null as unknown as User;
            })
          : (user as User);

        if (!fullUser) return;

        const senderName = fullUser.displayName || fullUser.username;
        const sender = fullUser.id;

        logger.info(
          { chatJid, emoji: emojiName, approvalText, sender: senderName },
          'Discord reaction approval received',
        );

        // Synthesise as a regular message — include reply_to_message_id so the
        // agent knows which of its messages was approved.
        this.opts.onMessage(chatJid, {
          id: `reaction-${message.id}-${sender}`,
          chat_jid: chatJid,
          sender,
          sender_name: senderName,
          content: approvalText,
          timestamp: new Date().toISOString(),
          is_from_me: false,
          reply_to_message_id: message.id,
        });
      },
    );

    // Handle errors gracefully
    this.client.on(Events.Error, (err) => {
      logger.error({ err: err.message }, 'Discord client error');
    });

    return new Promise<void>((resolve) => {
      this.client!.once(Events.ClientReady, (readyClient) => {
        logger.info(
          { username: readyClient.user.tag, id: readyClient.user.id },
          'Discord bot connected',
        );
        console.log(`\n  Discord bot: ${readyClient.user.tag}`);
        console.log(
          `  Use /chatid command or check channel IDs in Discord settings\n`,
        );
        resolve();
      });

      this.client!.login(this.botToken);
    });
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    if (!this.client) {
      logger.warn('Discord client not initialized');
      return;
    }

    try {
      const channelId = jid.replace(/^dc:/, '');
      const channel = await this.client.channels.fetch(channelId);

      if (!channel || !('send' in channel)) {
        logger.warn({ jid }, 'Discord channel not found or not text-based');
        return;
      }

      const textChannel = channel as TextChannel;

      // Discord has a 2000 character limit per message — split if needed
      const MAX_LENGTH = 2000;
      if (text.length <= MAX_LENGTH) {
        await textChannel.send(text);
      } else {
        for (let i = 0; i < text.length; i += MAX_LENGTH) {
          await textChannel.send(text.slice(i, i + MAX_LENGTH));
        }
      }
      logger.info({ jid, length: text.length }, 'Discord message sent');
    } catch (err) {
      logger.error({ jid, err }, 'Failed to send Discord message');
    }
  }

  isConnected(): boolean {
    return this.client !== null && this.client.isReady();
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('dc:');
  }

  async disconnect(): Promise<void> {
    if (this.client) {
      this.client.destroy();
      this.client = null;
      logger.info('Discord bot stopped');
    }
  }

  async setTyping(jid: string, isTyping: boolean): Promise<void> {
    if (!this.client || !isTyping) return;
    try {
      const channelId = jid.replace(/^dc:/, '');
      const channel = await this.client.channels.fetch(channelId);
      if (channel && 'sendTyping' in channel) {
        await (channel as TextChannel).sendTyping();
      }
    } catch (err) {
      logger.debug({ jid, err }, 'Failed to send Discord typing indicator');
    }
  }
}

registerChannel('discord', (opts: ChannelOpts) => {
  const envVars = readEnvFile(['DISCORD_BOT_TOKEN']);
  const token =
    process.env.DISCORD_BOT_TOKEN || envVars.DISCORD_BOT_TOKEN || '';
  if (!token) {
    logger.warn('Discord: DISCORD_BOT_TOKEN not set');
    return null;
  }
  return new DiscordChannel(token, opts);
});
