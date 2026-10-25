-- Owner-managed Allowed Folders published by a Workspace Service. Only the
-- path-free summary is stored; absolute paths never leave the Workspace.
CREATE TABLE workspace_allowed_folders (
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  folder_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('available','read_only','denied','missing')),
  checked_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, folder_id)
);

-- Folders a Space owner attached to a Space. Attachments belong to one
-- Workspace; removing the folder or changing the Space Workspace detaches it.
CREATE TABLE space_additional_folders (
  space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL,
  folder_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (space_id, folder_id),
  FOREIGN KEY (workspace_id, folder_id)
    REFERENCES workspace_allowed_folders(workspace_id, folder_id) ON DELETE CASCADE
);
CREATE INDEX space_additional_folders_workspace
  ON space_additional_folders(workspace_id, folder_id);
