import { sendJson, sendError } from '../utils/response.js';
import { postByIdStmt, createPostStmt, insertLikeStmt, updatePostByIdStmt } from '../db/posts.js';
import { requireAuth } from '../auth/require-auth.js';
import { ERRORS } from '../utils/errors.js';
import { validatePostBody } from '../utils/validate.js';
import { readRequestBody } from '../utils/request-body.js'

const validatePostId = (postId, res) => {

    const numPostId = Number(postId);

    if (Number.isNaN(numPostId)) {
        sendError(res, 400, ERRORS.INVALID_POST_ID);
        return null;
    }

    if (numPostId < 1) {
        sendError(res, 400, ERRORS.INVALID_POST_ID);
        return null;
    }

    if (!Number.isInteger(numPostId)) {
        sendError(res, 400, ERRORS.INVALID_POST_ID);
        return null;
    }

    return numPostId;
};

export async function getPostById(req, res, postId) {
    const validatedPostId = validatePostId(postId, res);
    
    if (!validatedPostId) return;

    try {
    
        const row = postByIdStmt.get(postId);

        if (!row) {
            return sendError(
                res,
                404,
                ERRORS.POST_NOT_FOUND
            );
        }

        res.statusCode = 200;
        res.setHeader(
            'Content-Type',
            'application/json'
        );

        return res.end(row.payload);

    } catch {
        return sendError(res, 500, ERRORS.INTERNAL_SERVER_ERROR);
    }
}

export async function getAllPosts(req, res) {

    if(!requireAuth(req, res)) return;

    try {
        return sendError(res, 500, ERRORS.INTERNAL_SERVER_ERROR);
    } catch {
        return sendError(res, 500, ERRORS.INTERNAL_SERVER_ERROR);
    }
}

export async function createPost(req, res) {
    const auth = requireAuth(req, res);

    if (!auth) {
        return;
    }

    try {
        const rawBody = await readRequestBody(req);

        const payload = JSON.parse(rawBody);

        const postBody = validatePostBody(
            payload.body,
            res
        );

        if (!postBody) {
            return;
        }

        const row = createPostStmt.get(
            auth.userId,
            postBody
        );

        return sendJson(res, 201, {
            post: {
                id: row.id,
                body: postBody,
                created_at: row.created_at,
                author: auth.username,
                like_count: 0
            }
        });

    } catch (error) {



        if (error instanceof SyntaxError) {
            return sendError(
                res,
                400,
                ERRORS.MALFORMED_JSON_BODY
            );
        }

        return sendError(
            res,
            500,
            ERRORS.INTERNAL_SERVER_ERROR
        );
    }
}

export async function updatePost(req, res) {
    if (!requireAuth(req, res)) return;
    
    const validatedPostId = validatePostId(req.url.split('/')[2], res);

    if(!validatedPostId) return;

    try {
        const body = await readRequestBody(req);

        const payload = JSON.parse(body);

        const postBody = payload.body?.trim();

        if (!postBody) {
            return sendError(
                res,
                400,
                ERRORS.BODY_REQUIRED
            );
        }

        const post = updatePostByIdStmt.get(
            postBody,
            validatePostId
        );

        if (!post) {
            return sendError(
                res,
                404,
                ERRORS.POST_NOT_FOUND
            );
        }

        return sendJson(res, 200, {
            post
        });

    } catch (error) {

        if (error instanceof SyntaxError) {
            return sendError(
                res,
                400,
                ERRORS.MALFORMED_JSON_BODY
            );
        }

        return sendError(
            res,
            500,
            ERRORS.INTERNAL_SERVER_ERROR
        );
    }
}

export async function likePost(req, res, postId) {

    const auth = requireAuth(req, res);

    if (!auth) return;

    const validatedPostId = validatePostId(postId, res);

    if (!validatedPostId) return;

    try {

        const post = postByIdStmt.get(validatedPostId);

        if (!post) {

            return sendError(
                res,
                404,
                ERRORS.POST_NOT_FOUND
            );
        }

        const result = insertLikeStmt.run(
            auth.userId,
            validatedPostId
        );

        return sendJson(
            res,
            result.changes === 1 ? 201 : 200,
            {
                liked: true,
                already_liked:
                result.changes === 0,
                post_id: validatedPostId
            }
        );

    } catch (error) {

        console.error(error);

        return sendError(
            res,
            500,
            ERRORS.INTERNAL_SERVER_ERROR
        );
    }
}