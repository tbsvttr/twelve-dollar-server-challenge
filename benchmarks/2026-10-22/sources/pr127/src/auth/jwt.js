import crypto from 'node:crypto';

const JWT_SECRET =
    process.env.JWT_SECRET ??
    'twelve-dollar-challenge';

export function verifyAuth(req) {
    
    const authorization = req.headers.authorization;

    if (
        !authorization ||
        !authorization.startsWith('Bearer ')
    ) {
        return {
            ok: false,
            status: 401,
            error: 'missing bearer token'
        };
    }

    const token = authorization.slice(7);

    try {
        const parts = token.split('.');

        if (parts.length !== 3) {
            throw new Error();
        }

        const [
            encodedHeader,
            encodedPayload,
            signature
        ] = parts;

        const header = JSON.parse(
            Buffer
                .from(encodedHeader, 'base64url')
                .toString('utf8')
        );

        if (header.alg !== 'HS256') {
            return {
                ok: false,
                status: 401,
                error: 'invalid or expired token'
            };
        }

        const expectedSignature = crypto
            .createHmac('sha256', JWT_SECRET)
            .update(
                `${encodedHeader}.${encodedPayload}`
            )
            .digest('base64url');

        if (expectedSignature !== signature) {
            return {
                ok: false,
                status: 401,
                error: 'invalid or expired token'
            };
        }

        const payload = JSON.parse(
            Buffer
                .from(encodedPayload, 'base64url')
                .toString('utf8')
        );

        const now =
            Math.floor(Date.now() / 1000);

        if (
            typeof payload.exp !== 'number' ||
            payload.exp <= now
        ) {
            return {
                ok: false,
                status: 401,
                error: 'invalid or expired token'
            };
        }

        const userId =
            Number(payload.sub);

        if (
            typeof payload.sub !== 'string' ||
            !Number.isInteger(userId) ||
            userId <= 0 ||
            String(userId) !== payload.sub
        ) {
            return {
                ok: false,
                status: 401,
                error: 'invalid token payload'
            };
        }

        if (
            typeof payload.username !== 'string'
        ) {
            return {
                ok: false,
                status: 401,
                error: 'invalid token payload'
            };
        }

        return {
            ok: true,
            userId,
            username: payload.username
        };

    } catch {
        return {
            ok: false,
            status: 401,
            error: 'invalid or expired token'
        };
    }
}