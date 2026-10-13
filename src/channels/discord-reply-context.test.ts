/**
 * Direct unit tests for the Discord extractReplyContext helper.
 */
import { describe, expect, it } from 'vitest';

import { extractReplyContext } from './discord.js';

describe('extractReplyContext', () => {
  it('returns {text, sender, id} when referenced_message has all fields', () => {
    const raw = {
      referenced_message: {
        id: '1234567890',
        content: 'hello world',
        author: { global_name: 'Alice', username: 'alice123' },
      },
    };
    expect(extractReplyContext(raw)).toEqual({
      text: 'hello world',
      sender: 'Alice',
      id: '1234567890',
    });
  });

  it('returns null when no referenced_message', () => {
    expect(extractReplyContext({})).toBeNull();
    expect(extractReplyContext({ referenced_message: null })).toBeNull();
    expect(extractReplyContext({ referenced_message: undefined })).toBeNull();
  });

  it('returns {text, sender} with undefined id when referenced_message.id is absent', () => {
    const raw = {
      referenced_message: {
        content: 'some reply',
        author: { username: 'bob99' },
      },
    };
    const result = extractReplyContext(raw);
    expect(result).toEqual({
      text: 'some reply',
      sender: 'bob99',
      id: undefined,
    });
  });
});
