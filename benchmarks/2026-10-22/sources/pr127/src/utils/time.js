const startedAt = Date.now();

export const getUptimeSeconds = () => {
  return ((Date.now() - startedAt) / 1000) | 0;
};