import { afterEach, describe, expect, test } from 'bun:test';

import { closeSessionDb, initTestSessionDb } from './connection.js';
import { SqliteAgentMailbox } from './index.js';
import { sqliteGetSeqByPlatformMessageId } from './operations.js';

afterEach(() => closeSessionDb());

describe('SQLite runner mailbox canonical serialization', () => {
  test('classifies only corruption errors as requiring a fresh runner', () => {
    const mailbox = new SqliteAgentMailbox();
    expect(mailbox.shouldRestartAfter(new Error('database disk image is malformed'))).toBe(true);
    expect(mailbox.shouldRestartAfter('SqliteError: SQLITE_CORRUPT_VTAB: ...')).toBe(true);
    expect(mailbox.shouldRestartAfter('file is not a database')).toBe(true);
    expect(mailbox.shouldRestartAfter('database is locked')).toBe(false);
    expect(mailbox.shouldRestartAfter('no such table: messages_in')).toBe(false);
  });

  test('round-trips full inbound and outbound lifecycle records', async () => {
    const { inbound, outbound } = initTestSessionDb();
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, process_after, recurrence, series_id, tries, trigger,
            platform_id, channel_type, thread_id, content, on_wake)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        'in-1',
        2,
        'chat',
        '2026-01-01 00:00:00',
        'pending',
        null,
        null,
        'in-1',
        0,
        1,
        'room',
        'test',
        'thread',
        '{"text":"hello"}',
        1,
      );
    inbound
      .prepare(
        `INSERT INTO destinations
           (name, display_name, type, channel_type, platform_id, agent_group_id)
         VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .run('test-room', null, 'channel', 'test', 'room', null);
    outbound
      .prepare('INSERT INTO session_state (key, value, updated_at) VALUES (?, ?, ?)')
      .run('continuation', 'token', '2026-01-01 00:00:00');

    const mailbox = new SqliteAgentMailbox();
    await mailbox.start({ agentGroupId: 'agent', sessionId: 'session', mailbox: null });
    expect(mailbox.getPendingMessages(10, true)).toEqual([
      {
        id: 'in-1',
        sequence: 2,
        kind: 'chat',
        timestamp: '2026-01-01T00:00:00.000Z',
        status: 'pending',
        processAfter: null,
        recurrence: null,
        seriesId: 'in-1',
        tries: 0,
        trigger: true,
        platformId: 'room',
        channelType: 'test',
        threadId: 'thread',
        content: '{"text":"hello"}',
        sourceSessionId: null,
        onWake: true,
      },
    ]);
    expect(mailbox.getState('continuation')).toEqual({
      value: 'token',
      updatedAt: '2026-01-01T00:00:00.000Z',
    });
    expect(mailbox.getDestinations()).toEqual([
      {
        name: 'test-room',
        displayName: null,
        type: 'channel',
        channelType: 'test',
        platformId: 'room',
        agentGroupId: null,
      },
    ]);

    for (const invalidTimeout of [-1, 1.5]) {
      mailbox.setContainerToolInFlight('Bash', invalidTimeout);
      expect(outbound.prepare('SELECT current_tool, tool_declared_timeout_ms FROM container_state').get()).toEqual({
        current_tool: 'Bash',
        tool_declared_timeout_ms: null,
      });
    }

    expect(
      await mailbox.writeMessageOut({
        id: 'out-1',
        inReplyTo: 'in-1',
        deliverAfter: '2026-01-01T00:00:01.000Z',
        recurrence: '0 * * * *',
        kind: 'chat',
        platformId: 'room',
        channelType: 'test',
        threadId: 'thread',
        content: '{"text":"reply"}',
      }),
    ).toBe(3);
    expect(mailbox.getUndeliveredMessages()).toEqual([
      {
        id: 'out-1',
        sequence: 3,
        inReplyTo: 'in-1',
        timestamp: expect.any(String),
        deliverAfter: '2026-01-01T00:00:01.000Z',
        recurrence: '0 * * * *',
        kind: 'chat',
        platformId: 'room',
        channelType: 'test',
        threadId: 'thread',
        content: '{"text":"reply"}',
      },
    ]);
  });

  test('resolves a reaction on an agent-authored outbound message to its seq', () => {
    const { inbound, outbound } = initTestSessionDb();
    // Inbound user message — reaction on this already works today.
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, trigger, content)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run('111222333:agent', 2, 'chat', '2026-01-01 00:00:00', 'pending', 1, '{"text":"hi"}');
    // Agent's own outbound message with an odd seq, delivered to platform id MSG_OUT.
    outbound
      .prepare(
        `INSERT INTO messages_out
           (id, seq, timestamp, kind, content)
         VALUES (?, ?, ?, ?, ?)`,
      )
      .run('out-1', 3, '2026-01-01 00:00:01', 'chat', '{"text":"reply"}');
    inbound
      .prepare(
        `INSERT INTO delivered
           (message_out_id, platform_message_id, status, delivered_at)
         VALUES (?, ?, ?, ?)`,
      )
      .run('out-1', '999888777', 'delivered', '2026-01-01 00:00:02');

    // Reaction on the agent's own outbound message resolves via delivered -> messages_out.
    expect(sqliteGetSeqByPlatformMessageId('999888777')).toBe(3);
    // Reaction on a stored inbound user message still resolves (no regression).
    expect(sqliteGetSeqByPlatformMessageId('111222333')).toBe(2);
    // Unknown snowflake returns null (graceful degradation).
    expect(sqliteGetSeqByPlatformMessageId('000000000')).toBeNull();
  });

  test('skips malformed pending inbound rows instead of crashing the runner', () => {
    const { inbound } = initTestSessionDb();
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, process_after, recurrence, series_id, tries, trigger,
            platform_id, channel_type, thread_id, content, on_wake)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        'bad-row',
        2,
        'not-a-kind',
        new Date().toISOString(),
        'pending',
        null,
        null,
        null,
        0,
        1,
        null,
        null,
        null,
        '{}',
        0,
      );

    const mailbox = new SqliteAgentMailbox();
    expect(mailbox.getPendingMessages(10, false)).toEqual([]);
  });
});
