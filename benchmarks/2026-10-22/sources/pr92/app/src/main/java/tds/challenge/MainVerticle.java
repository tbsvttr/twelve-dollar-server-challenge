package tds.challenge;

import io.vertx.core.Future;
import io.vertx.core.http.HttpServer;
import io.vertx.core.json.JsonObject;
import tds.challenge.db.DbThread;
import tds.challenge.repository.PostRepository;
import tds.challenge.web.ApiHandler;
import tds.challenge.web.Routes;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Handler;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.Optional;

public class MainVerticle extends AbstractVerticle {

    private DbThread writer;
    private DbThread reader;
    private HttpServer server;

    @Override
    public void start(Promise<Void> startPromise) {
        final String host = Optional.ofNullable(System.getenv("HOST")).orElseThrow(() -> new IllegalStateException("Require HOST env-var"));
        final int port = Integer.parseInt(Optional.ofNullable(System.getenv("PORT")).orElseThrow(() -> new IllegalStateException("Require PORT env-var")));
        final String sqlitePath = Optional.ofNullable(System.getenv("SQLITE_PATH")).orElseThrow(() -> new IllegalStateException("Require SQLITE_PATH env-var"));
        final String jwtSecret = Optional.ofNullable(System.getenv("JWT_SECRET")).orElseThrow(() -> new IllegalStateException("Require JWT_SECRET env-var"));

        try {
            // specify a write and read thread
            writer = DbThread.writer(sqlitePath, context);
            reader = DbThread.reader(sqlitePath, context);
        } catch (Exception e) {
            closeDb();
            startPromise.fail(e);
            return;
        }

        // wonky lambda construction, to at least pretend there is some abstraction between db and router
        Handler<RoutingContext> dbHealthHandler = ctx -> {
            reader.verifyConnection()
                    .onSuccess(fill -> {
                        JsonObject json = new JsonObject();
                        fill.accept(json);
                        Routes.json(ctx, 200, json);
                    });
        };

        PostRepository posts = new PostRepository(reader, writer);
        ApiHandler apiHandler = new ApiHandler(posts);
        Router router = Routes.build(vertx, apiHandler, dbHealthHandler, jwtSecret);

        vertx.createHttpServer()
                .requestHandler(router)
                .listen(port, host)
                .onSuccess(s -> {
                    server = s;
                    System.out.printf("HTTP server listening on port %s%n", server.actualPort());
                    startPromise.complete();
                })
                .onFailure(err -> {
                    closeDb();
                    startPromise.fail(err);
                });
    }

    @Override
    public void stop(Promise<Void> stopPromise) {
        Future<Void> serverClosed = server != null ? server.close() : Future.succeededFuture();
        serverClosed
                .compose(v -> vertx.<Void>executeBlocking(() -> {
                    closeDb();
                    return null;
                }))
                .onComplete(stopPromise);
    }

    private void closeDb() {
        if (reader != null) reader.close();
        if (writer != null) writer.close();
    }

}
