import { feedStmt } from '../db/feed.js';
import { ERRORS } from '../utils/errors.js';

export function feedRoute(req, res) {
    try {
        const row = feedStmt.get();
        res.statusCode = 200;

        res.setHeader(
            'Content-Type',
            'application/json'
        );

        return res.end(row.payload);

    } catch {
        return sendError(
            res,
            500,
            ERRORS.INTERNAL_SERVER_ERROR
        );
    }
}