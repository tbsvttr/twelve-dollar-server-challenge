#include <gtest/gtest.h>
#include <sqlite3.h>
#include <unistd.h>

#include <cstdlib>
#include <new>
#include <string>

#include "app.hpp"
#include "test_util.hpp"

#if defined(__SANITIZE_ADDRESS__)
#define SRV_SANITIZED 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define SRV_SANITIZED 1
#endif
#endif

namespace {

size_t g_allocations = 0;
bool g_counting = false;

constexpr const char *kSchema = testutil::kTestSchema;

using View = eastl::string_view;

class AppTest : public ::testing::Test {
protected:
    void SetUp() override {
        char path[] = "/tmp/srv-app-test-XXXXXX";
        int fd = mkstemp(path);
        ASSERT_GE(fd, 0);
        close(fd);
        path_ = path;
        sqlite3 *raw = nullptr;
        ASSERT_EQ(sqlite3_open(path, &raw), SQLITE_OK);
        ASSERT_EQ(sqlite3_exec(raw, kSchema, nullptr, nullptr, nullptr), SQLITE_OK);
        sqlite3_exec(raw, "INSERT INTO users (id, username) VALUES (1,'alice'),(2,'bob'),(3,'caf\xC3\xA9');", nullptr, nullptr, nullptr);
        for (int i = 1; i <= 30; ++i) {
            std::string sql = "INSERT INTO posts (id, user_id, body, created_at) VALUES (" + std::to_string(i) + "," + std::to_string(i % 3 + 1) + ",'post number " + std::to_string(i) +
                              "','2025-01-01T00:00:" + (i < 10 ? "0" : "") + std::to_string(i) + ".000Z');";
            sqlite3_exec(raw, sql.c_str(), nullptr, nullptr, nullptr);
        }
        sqlite3_exec(raw, "INSERT INTO likes (user_id, post_id) VALUES (1,30),(2,30),(3,30),(1,29);", nullptr, nullptr, nullptr);
        sqlite3_close(raw);
        ASSERT_TRUE(db_.open(path));
    }

    void TearDown() override {
        std::remove(path_.c_str());
        std::remove((path_ + "-wal").c_str());
        std::remove((path_ + "-shm").c_str());
    }

    int call(srv::Method method, const std::string &path, const std::string &auth, const std::string &body, std::string &response) {
        srv::Request req;
        req.method = method;
        req.path = View(path.data(), path.size());
        req.authorization = View(auth.data(), auth.size());
        req.body = View(body.data(), body.size());
        int status = app_.handle(req, out_);
        response.assign(out_.data(), out_.size());
        return status;
    }

    int get(const std::string &path, std::string &response) { return call(srv::Method::Get, path, "", "", response); }

    std::string path_;
    srv::Db db_;
    srv::JwtVerifier jwt_{View("twelve-dollar-challenge")};
    srv::App app_{db_, jwt_};
    char buffer_[256 * 1024];
    srv::Writer out_{buffer_, sizeof buffer_};
};

size_t count(const std::string &text, const std::string &needle) {
    size_t n = 0;
    for (size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + needle.size())) ++n;
    return n;
}

}

#ifndef SRV_SANITIZED
void *operator new(size_t n) {
    if (g_counting) ++g_allocations;
    void *p = malloc(n ? n : 1);
    if (!p) throw std::bad_alloc();
    return p;
}

void operator delete(void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
#endif

TEST_F(AppTest, Health) {
    std::string body;
    EXPECT_EQ(get("/health", body), 200);
    EXPECT_EQ(body.rfind("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":", 0), 0u);
}

TEST_F(AppTest, FeedReturnsTheTwentyNewestInOrder) {
    std::string body;
    ASSERT_EQ(get("/feed", body), 200);
    EXPECT_EQ(count(body, "{\"id\":"), 20u);
    EXPECT_EQ(body.rfind("{\"posts\":[{\"id\":30,\"body\":\"post number 30\",\"created_at\":\"2025-01-01T00:00:30.000Z\",\"author\":\"alice\",\"like_count\":3}", 0), 0u);
    EXPECT_LT(body.find("\"id\":30"), body.find("\"id\":29"));
    EXPECT_NE(body.find("\"id\":11,"), std::string::npos);
    EXPECT_EQ(body.find("\"id\":10,"), std::string::npos);
    EXPECT_EQ(body.substr(body.size() - 2), "]}");
}

TEST_F(AppTest, GetPost) {
    std::string body;
    EXPECT_EQ(get("/posts/29", body), 200);
    EXPECT_EQ(body, "{\"post\":{\"id\":29,\"body\":\"post number 29\",\"created_at\":\"2025-01-01T00:00:29.000Z\",\"author\":\"caf\xC3\xA9\",\"like_count\":1}}");
    EXPECT_EQ(get("/posts/999", body), 404);
    EXPECT_EQ(body, "{\"error\":\"post not found\"}");
    for (const char *id : {"0", "-1", "abc", "1.5", "", "99999999999999999999"}) {
        EXPECT_EQ(get(std::string("/posts/") + id, body), 400) << id;
        EXPECT_EQ(body, "{\"error\":\"invalid post id\"}");
    }
}

TEST_F(AppTest, UnknownRoutesAndMethods) {
    std::string body;
    EXPECT_EQ(get("/nope", body), 404);
    EXPECT_EQ(body, "{\"error\":\"not found\"}");
    EXPECT_EQ(get("/posts/1/extra", body), 404);
    EXPECT_EQ(get("/feed/", body), 404);
    EXPECT_EQ(call(srv::Method::Other, "/feed", "", "", body), 404);
    EXPECT_EQ(call(srv::Method::Post, "/feed", "", "", body), 404);
    EXPECT_EQ(call(srv::Method::Get, "/posts/1/like", "", "", body), 404);
    EXPECT_EQ(call(srv::Method::Post, "/posts/like", testutil::user_token(1, "alice"), "", body), 404);
}

TEST_F(AppTest, CreatePostTrimsReturnsAndPersists) {
    std::string body;
    ASSERT_EQ(call(srv::Method::Post, "/posts", testutil::user_token(2, "bob"), "{\"body\":\"  hello \\\"world\\\"\\n\xC3\xA9  \"}", body), 201);
    EXPECT_EQ(body.rfind("{\"post\":{\"id\":31,\"body\":\"hello \\\"world\\\"\\n\xC3\xA9\",\"created_at\":\"", 0), 0u);
    EXPECT_NE(body.find("\",\"author\":\"bob\",\"like_count\":0}}"), std::string::npos);
    std::string again;
    ASSERT_EQ(get("/posts/31", again), 200);
    EXPECT_NE(again.find("\"body\":\"hello \\\"world\\\"\\n\xC3\xA9\""), std::string::npos);
    std::string feed;
    ASSERT_EQ(get("/feed", feed), 200);
    EXPECT_EQ(feed.rfind("{\"posts\":[{\"id\":31,", 0), 0u);
}

TEST_F(AppTest, CreatePostValidation) {
    std::string body;
    const std::string auth = testutil::user_token(1, "alice");
    struct Case { const char *payload; int status; const char *error; };
    const Case cases[] = {
        {"", 400, "malformed JSON body"}, {"{bad json", 400, "malformed JSON body"}, {"{\"body\":\"x\"", 400, "malformed JSON body"},
        {"{}", 400, "body is required"}, {"[]", 400, "body is required"}, {"\"x\"", 400, "body is required"}, {"{\"body\":123}", 400, "body is required"},
        {"{\"body\":null}", 400, "body is required"}, {"{\"body\":\"\"}", 400, "body is required"}, {"{\"body\":\"   \\n\\t \"}", 400, "body is required"},
    };
    for (const Case &c : cases) {
        EXPECT_EQ(call(srv::Method::Post, "/posts", auth, c.payload, body), c.status) << c.payload;
        EXPECT_EQ(body, std::string("{\"error\":\"") + c.error + "\"}") << c.payload;
    }
    EXPECT_EQ(call(srv::Method::Post, "/posts", auth, "{\"body\":\"" + std::string(500, 'a') + "\"}", body), 201);
    EXPECT_EQ(call(srv::Method::Post, "/posts", auth, "{\"body\":\"  " + std::string(500, 'b') + "  \"}", body), 201);
    EXPECT_EQ(call(srv::Method::Post, "/posts", auth, "{\"body\":\"" + std::string(501, 'a') + "\"}", body), 400);
    EXPECT_EQ(body, "{\"error\":\"body must be at most 500 characters\"}");
    std::string multibyte;
    for (int i = 0; i < 500; ++i) multibyte += "\xC3\xA9";
    EXPECT_EQ(call(srv::Method::Post, "/posts", auth, "{\"body\":\"" + multibyte + "\"}", body), 201);
    EXPECT_EQ(call(srv::Method::Post, "/posts", auth, "{\"body\":\"" + multibyte + "\xC3\xA9\"}", body), 400);
}

TEST_F(AppTest, AuthIsCheckedBeforeEverythingElse) {
    std::string body;
    EXPECT_EQ(call(srv::Method::Post, "/posts", "", "{bad", body), 401);
    EXPECT_EQ(body, "{\"error\":\"missing bearer token\"}");
    EXPECT_EQ(call(srv::Method::Post, "/posts/abc/like", "", "", body), 401);
    EXPECT_EQ(call(srv::Method::Post, "/posts", "Bearer a.b.c", "{}", body), 401);
    EXPECT_EQ(body, "{\"error\":\"invalid or expired token\"}");
    EXPECT_EQ(call(srv::Method::Post, "/posts", testutil::token(R"({"alg":"HS256"})", R"({"sub":"x","username":"a"})"), "{}", body), 401);
    EXPECT_EQ(body, "{\"error\":\"invalid token payload\"}");
    EXPECT_EQ(call(srv::Method::Post, "/posts/abc/like", testutil::user_token(1, "alice"), "", body), 400);
}

TEST_F(AppTest, LikeFirstThenRepeat) {
    std::string body;
    const std::string auth = testutil::user_token(3, "caf\xC3\xA9");
    EXPECT_EQ(call(srv::Method::Post, "/posts/5/like", auth, "", body), 201);
    EXPECT_EQ(body, "{\"liked\":true,\"already_liked\":false,\"post_id\":5}");
    EXPECT_EQ(call(srv::Method::Post, "/posts/5/like", auth, "", body), 200);
    EXPECT_EQ(body, "{\"liked\":true,\"already_liked\":true,\"post_id\":5}");
    EXPECT_EQ(call(srv::Method::Post, "/posts/999/like", auth, "", body), 404);
    EXPECT_EQ(body, "{\"error\":\"post not found\"}");
    std::string post;
    ASSERT_EQ(get("/posts/5", post), 200);
    EXPECT_NE(post.find("\"like_count\":1}}"), std::string::npos);
}

TEST_F(AppTest, SteadyStateReadsAllocateNothing) {
#ifdef SRV_SANITIZED
    GTEST_SKIP() << "allocation counting is disabled under sanitizers";
#endif
    std::string warm;
    for (int i = 0; i < 3; ++i) {
        get("/feed", warm);
        get("/posts/7", warm);
        get("/health", warm);
        get("/posts/999", warm);
    }
    g_allocations = 0;
    g_counting = true;
    for (int i = 0; i < 200; ++i) {
        srv::Request req;
        req.method = srv::Method::Get;
        for (View path : {View("/feed"), View("/posts/7"), View("/health"), View("/posts/999"), View("/posts/x"), View("/nope")}) {
            req.path = path;
            app_.handle(req, out_);
        }
    }
    g_counting = false;
    EXPECT_EQ(g_allocations, 0u);
}
