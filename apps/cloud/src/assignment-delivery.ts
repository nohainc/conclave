export function assignmentDeliveryExpired(
  status: string,
  createdAt: string,
  now = Date.now(),
): boolean {
  return (
    (status === "created" || status === "dispatched") &&
    now - Date.parse(createdAt) >= 30_000
  );
}
