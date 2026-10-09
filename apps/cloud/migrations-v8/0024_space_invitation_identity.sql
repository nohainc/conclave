-- Known collaborators keep their invitation identity even if their email changes.
ALTER TABLE space_invitations ADD COLUMN invitee_user_id TEXT REFERENCES users(id) ON DELETE CASCADE;
UPDATE space_invitations SET invitee_user_id=accepted_by_user_id WHERE accepted_by_user_id IS NOT NULL;
-- Pending legacy email invitations remain email-addressed until accepted.
CREATE UNIQUE INDEX idx_space_invitations_pending_user ON space_invitations(space_id,invitee_user_id)
WHERE status='pending' AND invitee_user_id IS NOT NULL;
CREATE INDEX idx_space_invitations_invitee ON space_invitations(invitee_user_id,status);
