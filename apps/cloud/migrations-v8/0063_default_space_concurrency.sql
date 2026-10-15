-- Spaces may run up to three assignments in parallel on a Workspace. Only
-- grants still holding the former default of one are raised; any explicit
-- value chosen for a grant is left untouched.
UPDATE workspace_space_grants
   SET concurrency_json = '{"maxConcurrentAssignments":3}'
 WHERE concurrency_json = '{"maxConcurrentAssignments":1}';
