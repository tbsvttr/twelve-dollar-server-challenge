import { verifyAuth } from './jwt.js';
import { sendError } from '../utils/response.js';

export function requireAuth(req, res) {
    const auth = verifyAuth(req);

    if (!auth.ok) {
        sendError(
            res,
            auth.status,
            auth.error
        );

        return null;
    }

    return auth;
}