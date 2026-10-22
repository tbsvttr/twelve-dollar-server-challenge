import { db } from './db.js';

export const postByIdStmt = db.prepare(`
SELECT CAST(
    json_object(
        'post',
        json_object(
            'id', p.id,
            'body', p.body,
            'created_at', p.created_at,
            'author', u.username,
            'like_count',
            (
                SELECT COUNT(*)
                FROM likes l
                WHERE l.post_id = p.id
            )
        )
    )
AS BLOB) AS payload
FROM posts p
JOIN users u
    ON u.id = p.user_id
WHERE p.id = ?
`);

export const createPostStmt = db.prepare(`
INSERT INTO posts (
    user_id,
    body
)
VALUES (?, ?)
RETURNING id, created_at
`);

export const postExistsStmt = db.prepare(`
SELECT 1
FROM posts
WHERE id = ?
LIMIT 1
`);

export const insertLikeStmt = db.prepare(`
INSERT INTO likes (
user_id,
post_id
)
VALUES (?, ?)
ON CONFLICT(user_id, post_id)
DO NOTHING
`);

export const updatePostByIdStmt = db.prepare(`
    UPDATE posts
    SET body = ?
    WHERE id = ?
    RETURNING
        id,
        body,
        created_at
`);