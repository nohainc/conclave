-- One durable, undirected collaboration relationship, independent of Space lifetime.
CREATE TABLE people_relationships (
  user_low_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  established_at TEXT NOT NULL,
  PRIMARY KEY (user_low_id, user_high_id),
  CHECK (user_low_id < user_high_id)
);
CREATE INDEX idx_people_relationships_high ON people_relationships(user_high_id, user_low_id);
INSERT INTO people_relationships(user_low_id,user_high_id,established_at)
SELECT a.user_id,b.user_id,MIN(MAX(a.created_at,b.created_at))
FROM space_memberships a JOIN space_memberships b ON b.space_id=a.space_id AND a.user_id<b.user_id
GROUP BY a.user_id,b.user_id;
-- Membership creation is the establishment boundary; pending invitations never enter this trigger.
CREATE TRIGGER establish_people_on_membership AFTER INSERT ON space_memberships
BEGIN
  INSERT INTO people_relationships(user_low_id,user_high_id,established_at)
  SELECT MIN(NEW.user_id,m.user_id),MAX(NEW.user_id,m.user_id),NEW.created_at
  FROM space_memberships m WHERE m.space_id=NEW.space_id AND m.user_id<>NEW.user_id
  ON CONFLICT(user_low_id,user_high_id) DO NOTHING;
END;
-- Collapse historical duplicate pending invitations before enforcing race-safe uniqueness.
UPDATE space_invitations SET status='revoked'
WHERE status='pending' AND EXISTS (
  SELECT 1 FROM space_invitations older WHERE older.space_id=space_invitations.space_id
  AND LOWER(older.email)=LOWER(space_invitations.email) AND older.status='pending'
  AND (older.created_at<space_invitations.created_at OR (older.created_at=space_invitations.created_at AND older.id<space_invitations.id))
);
CREATE UNIQUE INDEX idx_space_invitations_pending_email ON space_invitations(space_id,LOWER(email)) WHERE status='pending';
