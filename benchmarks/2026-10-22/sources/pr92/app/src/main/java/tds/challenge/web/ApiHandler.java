package tds.challenge.web;

import io.vertx.ext.auth.User;
import tds.challenge.repository.PostRepository;
import io.vertx.core.json.DecodeException;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

public class ApiHandler {

    private final PostRepository posts;

    public ApiHandler(PostRepository posts) {
        this.posts = posts;
    }

    /**
     * GET /feed
     */
    public void feed(RoutingContext ctx) {
        posts.feed()
                .onSuccess(items -> {
                    JsonArray arr = new JsonArray();
                    items.forEach(arr::add);
                    JsonObject posts = new JsonObject()
                            .put("posts", arr);

                    Routes.json(ctx, 200, posts);
                })
                .onFailure(ctx::fail);
    }

    /**
     * GET /posts/:id
     */
    public void get(RoutingContext ctx) {
        long id;
        try {
            id = Long.parseLong(ctx.pathParam("id"));
        } catch (NumberFormatException e) {
            Routes.error(ctx, 400, "invalid post id");
            return;
        }
        if (id <= 0) {
            Routes.error(ctx, 400, "invalid post id");
            return;
        }

        posts.findById(id)
                .onSuccess(results -> {
                    if (!results.isEmpty()) {
                        JsonObject post = new JsonObject()
                                .put("post", results.getFirst());

                        Routes.json(ctx, 200, post);
                    } else {
                        Routes.error(ctx, 404, "post not found");
                    }
                })
                .onFailure(ctx::fail);
    }

    /**
     * POST /posts
     */
    public void create(RoutingContext ctx) {
        User user = verifyAuth(ctx);
        if (ctx.response().ended()) {
            return;
        }

        JsonObject body = verifyAndExtractBody(ctx);
        if (ctx.response().ended()) {
            return;
        }

        String postBody = body.getString("body");
        if (postBody == null || postBody.isBlank()) {
            Routes.error(ctx, 400, "body is required");
            return;
        } else if (postBody.trim().length() > 500) {
            Routes.error(ctx, 400, "body must be at most 500 characters");
            return;
        }

        postBody = postBody.trim();

        try {
            Long.parseLong(postBody);
            // apparently this body is numeric
            Routes.error(ctx, 400, "body is required");
            return;
        } catch (NumberFormatException nfe) {
            // ignore
        }

        final String username = user.get("username");
        final long userId = Long.parseLong(user.get("sub"));

        posts.insertPost(userId, username, postBody)
                .onSuccess((JsonObject insertedPost) -> {
                    JsonObject post = new JsonObject()
                            .put("post", insertedPost);

                    Routes.json(ctx, 201, post);
                })
                .onFailure(ctx::fail);
    }

    /**
     * POST /posts/:id/like
     */
    public void like(RoutingContext ctx) {
        User user = verifyAuth(ctx);
        if (ctx.response().ended()) {
            return;
        }

        long id;
        try {
            id = Long.parseLong(ctx.pathParam("id"));
        } catch (NumberFormatException e) {
            Routes.error(ctx, 400, "invalid post id");
            return;
        }
        if (id <= 0) {
            Routes.error(ctx, 400, "invalid post id");
            return;
        }
        final long userId = Long.parseLong(user.get("sub"));

        posts.likePost(userId, id)
                .onSuccess((Boolean wasLiked) -> {
                    JsonObject like = new JsonObject()
                            .put("liked", Boolean.TRUE)
                            .put("already_liked", !wasLiked)
                            .put("post_id", id);

                    Routes.json(ctx, wasLiked ? 201 : 200, like);
                })
                .onFailure(err -> {
                    if (err.getMessage().contains("SQLITE_CONSTRAINT_FOREIGNKEY")) {
                        // there is only one foreign key on likes table -> post does not exist
                        Routes.error(ctx, 404, "post not found");
                    } else {
                        ctx.fail(err);
                    }
                });
    }

    private static User verifyAuth(RoutingContext ctx) {
        User user = ctx.user();
        String username = user.get("username");
        if (username == null || username.isBlank()) {
            Routes.error(ctx, 401, "invalid token payload");
            return null;
        }

        try {
            Integer.parseInt(user.get("sub"));
        } catch (NumberFormatException nfe) {
            Routes.error(ctx, 401, "invalid token payload");
            return null;
        }

        return user;
    }

    private static JsonObject verifyAndExtractBody(RoutingContext ctx) {
        JsonObject body;
        try {
            body = ctx.body().asJsonObject();
        } catch (DecodeException e) {
            Routes.error(ctx, 400, "malformed JSON body");
            return null;
        }

        if (body == null) {
            Routes.error(ctx, 400, "malformed JSON body");
        }

        return body;
    }
}
