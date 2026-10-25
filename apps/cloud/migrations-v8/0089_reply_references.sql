-- Reply v1: a Chat message may reply to an earlier message, a Work Request,
-- or an AI response in the same Thread. The value is a server-built snapshot
-- {kind, id, authorName, excerpt} taken at send time, so the quote survives
-- edits and deletion of the original. Work Requests store the same snapshot
-- in their immutable input (input.replyTo); no column is needed there.
ALTER TABLE discussion_messages ADD COLUMN reply_to_json TEXT;
