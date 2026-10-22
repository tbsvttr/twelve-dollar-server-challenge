package tds.challenge;

import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;

public final class Main {

    private Main() {
    }

    public static void main(String[] args) {
        Vertx vertx = Vertx.vertx(new VertxOptions().setPreferNativeTransport(true).setEventLoopPoolSize(1).setWorkerPoolSize(2));

        vertx.deployVerticle(new MainVerticle())
                .onSuccess(id -> System.out.printf("Deployed MainVerticle [%s]%n", id))
                .onFailure(err -> {
                    System.out.printf("Failed to deploy MainVerticle: %s%n", err);
                    vertx.close();
                });

        // Graceful shutdown on Ctrl+C / SIGTERM (closes verticles -> closes Hikari pool)
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try {
                vertx.close().toCompletionStage().toCompletableFuture().get();
            } catch (Exception ignored) {
                // nothing sensible to do during JVM shutdown
            }
        }));
    }
}
