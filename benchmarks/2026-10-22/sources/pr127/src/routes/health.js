
import { healthStmt } from '../db/health.js';
import { sendJson } from '../utils/response.js';
import { getUptimeSeconds } from '../utils/time.js';

export const healthRoute = (req, res) => {
  try {
    healthStmt.get();

    sendJson(res, 200, {
      status: 'ok',
      db: 'ok',
      uptime_s: getUptimeSeconds()
    });

  } 
  
  catch (error) {
    sendJson(res, 503, {
      status: 'degraded',
      db: 'unreachable',
      error: error.message
    });
  }
};