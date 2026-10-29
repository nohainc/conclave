-- Read receipts are shared by default. A person who turns them off neither
-- shows when they read a Thread nor sees when others read theirs.
ALTER TABLE users ADD COLUMN share_read_receipts INTEGER NOT NULL DEFAULT 1
  CHECK (share_read_receipts IN (0, 1));
