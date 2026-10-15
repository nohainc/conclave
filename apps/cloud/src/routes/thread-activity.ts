/** SQL predicates for the sidebar indicators, shared by Thread and Space reads.
 * Work older than a day without an update is treated as abandoned so a stuck
 * row cannot show a permanent running indicator. */
export const activeWorkSql = (thread: string) => `EXISTS (
  SELECT 1 FROM work_requests w
   WHERE w.thread_id = ${thread}.id
     AND w.status IN ('queued', 'running', 'waiting')
     AND w.updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')
)`;

/** Unread means another user's Discussion message or a finished Work Request
 * is newer than `readSince`, a SQL expression for the user's read marker. */
export const unreadSql = (
  thread: string,
  userParam: string,
  readSince: string,
) => `(${readSince} IS NOT NULL AND (
  EXISTS (
    SELECT 1 FROM discussion_messages dm
     WHERE dm.thread_id = ${thread}.id
       AND dm.author_user_id <> ${userParam}
       AND dm.created_at > ${readSince}
  ) OR EXISTS (
    SELECT 1 FROM work_requests w
     WHERE w.thread_id = ${thread}.id
       AND w.status IN ('completed', 'failed')
       AND w.updated_at > ${readSince}
  )
))`;
