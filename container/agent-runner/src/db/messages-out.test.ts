/**
 * Tests for the runner-facing getMessageIdBySeq wrapper in db/messages-out.ts.
 *
 * Exercises the :agentGroupId namespace stripping that lets MCP tools
 * (add_reaction, edit_message) use the raw platform message ID.
 */
import { afterEach, beforeEach, describe, expect, test } from 'bun:test';

import { initTestSessionDb, closeSessionDb } from '../mailbox/sqlite/connection.js';
import { registerAgentMailbox, resetAgentMailboxForTesting } from '../mailbox/index.js';
import { SqliteAgentMailbox } from '../mailbox/sqlite/index.js';
import { runnerConfigFromRaw, setConfigForTesting } from '../config.js';
import { getMessageIdBySeq } from './messages-out.js';

let previousMailbox: ReturnType<typeof resetAgentMailboxForTesting>;

beforeEach(() => {
  previousMailbox = resetAgentMailboxForTesting();
  initTestSessionDb();
  registerAgentMailbox(() => new SqliteAgentMailbox());
});

afterEach(() => {
  setConfigForTesting(null);
  resetAgentMailboxForTesting();
  closeSessionDb();
  if (previousMailbox) registerAgentMailbox(previousMailbox);
});

describe('getMessageIdBySeq namespace stripping', () => {
  test('strips :agentGroupId suffix from inbound message ids', () => {
    const { inbound } = initTestSessionDb();
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, trigger, content, on_wake)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run('discord-snowflake-123:ag-test-group', 2, 'chat', new Date().toISOString(), 'pending', 1, '{}', 0);

    setConfigForTesting(runnerConfigFromRaw({ agentGroupId: 'ag-test-group' }));

    expect(getMessageIdBySeq(2)).toBe('discord-snowflake-123');
  });

  test('returns outbound message ids unchanged (not namespaced)', async () => {
    initTestSessionDb();
    setConfigForTesting(runnerConfigFromRaw({ agentGroupId: 'ag-test-group' }));

    const mailbox = new SqliteAgentMailbox();
    const seq = await mailbox.writeMessageOut({
      id: 'outbound-msg-1',
      kind: 'chat',
      content: '{"text":"hi"}',
    });

    expect(getMessageIdBySeq(seq)).toBe('outbound-msg-1');
  });

  test('returns raw id when config is not loaded', () => {
    const { inbound } = initTestSessionDb();
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, trigger, content, on_wake)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run('discord-snowflake-456:ag-other', 4, 'chat', new Date().toISOString(), 'pending', 1, '{}', 0);

    // Don't load config — getConfig() will throw, caught by the try/catch
    setConfigForTesting(null);

    expect(getMessageIdBySeq(4)).toBe('discord-snowflake-456:ag-other');
  });

  test('returns raw id when it does not end with :agentGroupId', () => {
    const { inbound } = initTestSessionDb();
    inbound
      .prepare(
        `INSERT INTO messages_in
           (id, seq, kind, timestamp, status, trigger, content, on_wake)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run('plain-id-no-suffix', 6, 'chat', new Date().toISOString(), 'pending', 1, '{}', 0);

    setConfigForTesting(runnerConfigFromRaw({ agentGroupId: 'ag-test-group' }));

    expect(getMessageIdBySeq(6)).toBe('plain-id-no-suffix');
  });
});
