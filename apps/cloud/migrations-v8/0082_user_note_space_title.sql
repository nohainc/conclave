-- Saved Space name for a Thread note, shown with the saved Thread title once
-- the note is detached from a deleted or inaccessible Thread.
ALTER TABLE user_notes ADD COLUMN linked_space_title TEXT;
