-- Manual order of a user's pins. Lower positions come first; ties (and pins
-- made before this column) fall back to the newest pin first.
ALTER TABLE user_pins ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
