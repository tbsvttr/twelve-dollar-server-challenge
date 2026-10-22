import { db } from './db.js';

export const feedStmt = db.prepare(`
SELECT CAST(
    json_object(
        'posts',
        json_group_array(
            json_object(
                'id', id,
                'body', body,
                'created_at', created_at,
                'author', author,
                'like_count', like_count
            )
        )
    )
AS BLOB) AS payload
FROM (
    SELECT
        p.id,
        p.body,
        p.created_at,
        u.username AS author,
        (
            SELECT COUNT(*)
            FROM likes l
            WHERE l.post_id = p.id
        ) AS like_count
    FROM posts p
    JOIN users u
        ON u.id = p.user_id
    ORDER BY p.id DESC
    LIMIT 20
);
`);