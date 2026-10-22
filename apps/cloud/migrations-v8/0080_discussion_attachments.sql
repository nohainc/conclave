-- Attachment references only; original bytes remain private in R2.
ALTER TABLE discussion_messages ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';
