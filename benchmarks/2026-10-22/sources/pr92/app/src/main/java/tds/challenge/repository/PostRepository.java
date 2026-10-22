package tds.challenge.repository;

import io.vertx.core.Future;
import io.vertx.core.json.JsonObject;
import tds.challenge.db.DbThread;
import tds.challenge.db.RowMapper;

import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;

public class PostRepository {

    private static final RowMapper<JsonObject> POST_MAPPER = rs ->
            new JsonObject()
                    .put("id", rs.getLong(1))
                    .put("body", rs.getString(2))
                    .put("created_at", rs.getString(3))
                    .put("author", rs.getString(4))
                    .put("like_count", rs.getLong(5));

    private static final String POST_SELECT = """
            SELECT p.id, p.body, p.created_at, u.username,
                   (SELECT count(*) FROM likes l WHERE l.post_id = p.id)
              FROM posts p JOIN users u ON u.id = p.user_id
            """;

    private static final String FEED_SQL = POST_SELECT + " ORDER BY p.created_at DESC, p.id DESC LIMIT 20;";
    private static final String SINGLE_POST_SQL = POST_SELECT + " WHERE p.id = ?;";

    private static final String INSERT_POST = "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at;";

    private static final String INSERT_LIKE = "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING";

    private final DbThread reader;
    private final DbThread writer;

    public PostRepository(DbThread reader, DbThread writer) {
        this.reader = reader;
        this.writer = writer;
    }

    public Future<List<JsonObject>> feed() {
        return reader.submit(s -> {
            try (ResultSet rs = s.prepare(FEED_SQL).executeQuery()) {
                return RowMapper.stream(rs, POST_MAPPER).toList();
            }
        });
    }

    public Future<List<JsonObject>> findById(long id) {
        return reader.submit(s -> {
            PreparedStatement ps = s.prepare(SINGLE_POST_SQL);
            ps.setLong(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                return RowMapper.stream(rs, POST_MAPPER).toList();
            }
        });
    }

    public Future<JsonObject> insertPost(long userId, String username, String postBody) {
        return writer.submit(s -> {
            PreparedStatement ps = s.prepare(INSERT_POST);
            ps.setLong(1, userId);
            ps.setString(2, postBody);

            try (ResultSet keys = ps.executeQuery()) {
                if (!keys.next()) {
                    throw new SQLException("Insert succeeded but no generated key was returned");
                }
                long id = keys.getLong(1);
                String createdAt = keys.getString(2);

                return new JsonObject()
                        .put("id", id)
                        .put("body", postBody)
                        .put("created_at", createdAt)
                        .put("author", username)
                        .put("like_count", 0);
            }
        });
    }

    public Future<Boolean> likePost(long userId, long postId) {
        return writer.submit(s -> {
            PreparedStatement ps = s.prepare(INSERT_LIKE);
            ps.setLong(1, userId);
            ps.setLong(2, postId);

            return ps.executeUpdate() != 0;
        });
    }
}
