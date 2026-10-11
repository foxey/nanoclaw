/**
 * Forwarded-gateway (Discord) approval button parse in the Chat SDK bridge.
 *
 * The Discord adapter encodes a button's custom_id as the triplet
 * `ncq:<approvalId>:<idx>` joined to `<value>` by a `\n` DELIMITER, e.g. the
 * Approve button is `ncq:appr-1:0\n0`. The bridge's forwarded
 * GATEWAY_INTERACTION_CREATE handler must strip everything from the first
 * newline BEFORE parsing the triplet; otherwise `tail` becomes '0\n0', the
 * index lookup (/^\d+$/) fails, the raw string is returned, and the
 * downstream `selectedOption !== 'approve'` test fails closed to reject on
 * every click.
 *
 * These tests drive the REAL `handleForwardedEvent` parse: a stub gateway
 * adapter + a captured `onAction` observe the resolved selectedOption. Before
 * the fix idx 0 resolved to '0\n0' (would FAIL these); after it resolves to
 * the real option value.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { Adapter } from 'chat';
import type { ChannelSetup } from './adapter.js';
import { handleForwardedEvent } from './chat-sdk-bridge.js';
import { registerQuestionRenderResolver } from './question-render-registry.js';

vi.mock('../webhook-server.js', () => ({
  registerWebhookAdapter: vi.fn(),
}));
vi.mock('../log.js', () => ({
  log: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn(), fatal: vi.fn() },
}));

const APPROVAL_ID = 'appr-forwarded-1';

/** Minimal gateway adapter surface handleForwardedEvent touches. */
function makeGatewayAdapter(): Adapter {
  return {
    name: 'discord',
    initialize: async () => {},
    channelIdFromThreadId: (threadId: string) => threadId,
    handleWebhook: async () => new Response('{}'),
  } as unknown as Adapter;
}

interface ActionCall {
  questionId: string;
  selectedOption: string;
  userId: string;
}

function makeHostConfig(): { hostConfig: ChannelSetup; actions: ActionCall[] } {
  const actions: ActionCall[] = [];
  const hostConfig: ChannelSetup = {
    onInbound: () => {},
    onInboundEvent: () => {},
    onMetadata: () => {},
    onAction: (questionId, selectedOption, userId) => {
      actions.push({ questionId, selectedOption, userId });
    },
  };
  return { hostConfig, actions };
}

/** A forwarded INTERACTION_CREATE body with the adapter's `\n`-suffixed id. */
function interactionBody(customId: string): string {
  return JSON.stringify({
    type: 'GATEWAY_INTERACTION_CREATE',
    data: {
      id: 'interaction-1',
      token: 'interaction-token',
      type: 3, // MessageComponent (button)
      channel_id: 'C1',
      member: { user: { id: 'U1', username: 'reviewer', global_name: 'Reviewer' } },
      message: { id: 'M1', embeds: [{ title: 'Approval needed', description: 'Install packages?' }] },
      data: { custom_id: customId },
    },
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  // The handler acknowledges the interaction via Discord's callback API; stub
  // it so the parse path runs without real network.
  fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 });
  vi.stubGlobal('fetch', fetchMock);
  registerQuestionRenderResolver((questionId) =>
    questionId === APPROVAL_ID
      ? {
          title: 'Install packages?',
          options: [
            { label: 'Approve', selectedLabel: '✅ Approved', value: 'approve' },
            { label: 'Reject', selectedLabel: '❌ Rejected', value: 'reject' },
            { label: 'Reject with reason', selectedLabel: '✍️ Rejected', value: 'reject_with_reason' },
          ],
        }
      : undefined,
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('chat-sdk bridge forwarded-gateway approval parse', () => {
  it.each([
    ['0', 'approve'],
    ['1', 'reject'],
    ['2', 'reject_with_reason'],
  ])('resolves the \\n-suffixed custom_id index %s to %s', async (idx, expected) => {
    const { hostConfig, actions } = makeHostConfig();
    // The adapter joins the triplet to the value with a `\n` DELIMITER.
    const customId = `ncq:${APPROVAL_ID}:${idx}\n${idx}`;

    await handleForwardedEvent(interactionBody(customId), makeGatewayAdapter(), hostConfig);

    expect(actions).toEqual([{ questionId: APPROVAL_ID, selectedOption: expected, userId: 'U1' }]);
  });
});
