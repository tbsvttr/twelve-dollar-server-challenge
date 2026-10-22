package tds.challenge.web;

import io.vertx.core.Handler;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpHeaders;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.auth.PubSecKeyOptions;
import io.vertx.ext.auth.jwt.JWTAuth;
import io.vertx.ext.auth.jwt.JWTAuthOptions;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;
import io.vertx.ext.web.handler.JWTAuthHandler;

public final class Routes {

    private Routes() {
    }

    public static Router build(Vertx vertx, ApiHandler items, Handler<RoutingContext> dbHealthHandler, String jwtSecret) {
        JWTAuth jwt = JWTAuth.create(vertx, new JWTAuthOptions()
                .addPubSecKey(new PubSecKeyOptions().setAlgorithm("HS256").setBuffer(jwtSecret)));
        JWTAuthHandler authHandler = JWTAuthHandler.create(jwt);

        Router router = Router.router(vertx);

        router.route().handler(BodyHandler.create().setBodyLimit(1024 * 1024));

        router.get("/health").handler(dbHealthHandler);

        router.get("/feed").handler(items::feed); // ok
        router.get("/posts/:id").handler(items::get); // ok
        router.post("/posts").handler(authHandler).handler(items::create);
        router.post("/posts/:id/like").handler(authHandler).handler(items::like);

        router.route().handler(ctx -> error(ctx, 404, "not found"));
        router.route().failureHandler(Routes::handleFailure);
        return router;
    }

    private static void handleFailure(RoutingContext ctx) {
        final int status = ctx.statusCode() > 0 ? ctx.statusCode() : 500;

        if (status >= 500) {
            System.out.printf("Unhandled error on %s %s%n", ctx.request().method(), ctx.request().path());
            ctx.failure().printStackTrace();
        } else if (status == 401) {
            String authHeader = ctx.request().getHeader("Authorization");
            if (authHeader == null || authHeader.isBlank() || authHeader.startsWith("Basic")) {
                error(ctx, status, "missing bearer token");
            }

            Throwable cause = ctx.failure();
            while (cause.getCause() != null) {
                cause = cause.getCause();
            }

            final String message = cause.getMessage();

            if (message.contains("Invalid format for JWT")
                    || message.contains("Signature verification failed")
                    || message.contains("JWT is in secure mode but token is not signed.")
                    || message.contains("Invalid JWT token: token expired.")) {
                error(ctx, status, "invalid or expired token");
            }
        }

        if (!ctx.response().ended()) {
            error(ctx, status, status >= 500 ? "Internal server error" : "Request failed");
        }
    }

    public static void json(RoutingContext ctx, int status, JsonObject body) {
        ctx.response()
                .setStatusCode(status)
                .putHeader(HttpHeaders.CONTENT_TYPE, "application/json")
                .end(body.encode());
    }

    public static void error(RoutingContext ctx, int status, String message) {
        json(ctx, status, new JsonObject().put("error", message));
    }
}
