// Checks the emitted header against the rules written out independently here, for every value of every table.
// Theorems cover the LexLean definitions; this covers the text that reached C, which no theorem does.
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "core.h"

static int failures;

#define CHECK(condition, ...)              \
    do {                                   \
        if (!(condition)) {                \
            failures++;                    \
            fprintf(stderr, __VA_ARGS__);  \
            fputc('\n', stderr);           \
        }                                  \
    } while (0)

static int expected_class(int byte) {
    if (byte == '"' || byte == '\\') return ESCAPE_BACKSLASH;
    return byte < 0x20 ? ESCAPE_UNICODE : ESCAPE_PLAIN;
}

static void test_bytes(void) {
    for (int byte = 0; byte < 256; byte++) {
        CHECK(ESCAPE_CLASS[byte] == expected_class(byte), "class of byte %d", byte);
        int needs = expected_class(byte) != ESCAPE_PLAIN;
        // The word test is carried text with no theorem, so every byte in every lane, among plain and awkward neighbours.
        const uint8_t neighbours[] = {'a', 0x7f, 0x80, 0xff, 0x20, 0x21, 0x23, 0x5b, 0x5d};
        for (size_t n = 0; n < sizeof neighbours; n++) {
            for (int lane = 0; lane < 8; lane++) {
                uint8_t bytes[8];
                memset(bytes, neighbours[n], 8);
                bytes[lane] = (uint8_t)byte;
                uint64_t word;
                memcpy(&word, bytes, 8);
                CHECK(word_needs_escape(word) == needs, "word test: byte %d lane %d neighbour %d", byte, lane, neighbours[n]);
            }
        }
    }
}

static void test_batch(void) {
    CHECK(NEXT_PHASE[PHASE_IDLE][EVENT_REQUEST] == PHASE_READING, "a request starts reading");
    CHECK(NEXT_PHASE[PHASE_READING][EVENT_BATCH_END] == PHASE_COMMITTING, "a batch end starts committing");
    CHECK(ACTION_OF[PHASE_READING][EVENT_BATCH_END] == ACTION_COMMIT, "a batch end commits");
    CHECK(ACTION_OF[PHASE_COMMITTING][EVENT_COMMIT_OK] == ACTION_SEND_ALL, "a commit sends");
    CHECK(ACTION_OF[PHASE_COMMITTING][EVENT_COMMIT_FAIL] == ACTION_FAIL_ALL, "a failed commit fails");
    CHECK(NEXT_PHASE[PHASE_COMMITTING][EVENT_COMMIT_OK] == PHASE_IDLE, "a commit ends the batch");
    CHECK(NEXT_PHASE[PHASE_COMMITTING][EVENT_COMMIT_FAIL] == PHASE_IDLE, "a failed commit ends the batch");
    for (int phase = 0; phase < 3; phase++) {
        for (int event = 0; event < 4; event++) {
            int action = ACTION_OF[phase][event];
            if (action == ACTION_SEND_ALL) CHECK(phase == PHASE_COMMITTING && event == EVENT_COMMIT_OK, "send at %d %d", phase, event);
            if (action == ACTION_FAIL_ALL) CHECK(phase == PHASE_COMMITTING && event == EVENT_COMMIT_FAIL, "fail at %d %d", phase, event);
        }
    }
}

static void test_routes(void) {
    static const struct { int method, shape, route; } routes[] = {
        {METHOD_GET, SHAPE_FEED, ROUTE_FEED},
        {METHOD_GET, SHAPE_HEALTH, ROUTE_HEALTH},
        {METHOD_GET, SHAPE_POST_ID, ROUTE_POST},
        {METHOD_POST, SHAPE_POSTS, ROUTE_CREATE},
        {METHOD_POST, SHAPE_POST_LIKE, ROUTE_LIKE},
    };
    for (int method = 0; method < 3; method++) {
        for (int shape = 0; shape < 6; shape++) {
            int expected = ROUTE_NOT_FOUND;
            for (size_t i = 0; i < sizeof routes / sizeof routes[0]; i++) {
                if (routes[i].method == method && routes[i].shape == shape) expected = routes[i].route;
            }
            CHECK(ROUTE_OF[method][shape] == expected, "route of %d %d", method, shape);
        }
    }
    for (int route = 0; route < 6; route++) {
        CHECK(ROUTE_NEEDS_TOKEN[route] == (route == ROUTE_CREATE || route == ROUTE_LIKE), "token for route %d", route);
    }
}

static void test_flow(void) {
    for (int index = 0; index < 16; index++) {
        int a = index >> 3 & 1, b = index >> 2 & 1, c = index >> 1 & 1, d = index & 1;
        CHECK(SHOULD_HOLD[index] == (a && (d || (b && c))), "hold at %d", index);
        CHECK(GATE_NEXT[index] == (a ? !(c || d) : b), "gate at %d", index);
    }
}

static void test_failures(void) {
    static const struct { int status; const char *reason, *message; } table[E_COUNT] = {
        FAILURE_ROW_0, FAILURE_ROW_1, FAILURE_ROW_2, FAILURE_ROW_3, FAILURE_ROW_4,
        FAILURE_ROW_5, FAILURE_ROW_6, FAILURE_ROW_7, FAILURE_ROW_8, FAILURE_ROW_9,
    };
    for (int i = 0; i < E_COUNT; i++) {
        CHECK((table[i].status >= 500) == (i == E_INTERNAL), "status of failure %d", i);
        CHECK(table[i].reason[0] && table[i].message[0], "text of failure %d", i);
    }
    CHECK(table[E_NO_BEARER].status == 401 && table[E_BAD_TOKEN].status == 401 && table[E_BAD_PAYLOAD].status == 401, "token failures are 401");
    CHECK(table[E_NOT_FOUND].status == 404 && table[E_POST_MISSING].status == 404, "missing things are 404");
    CHECK(table[E_BAD_ID].status == 400 && table[E_BAD_JSON].status == 400 && table[E_NO_BODY].status == 400 && table[E_LONG_BODY].status == 400, "bad input is 400");
}

int main(void) {
    test_bytes();
    test_batch();
    test_routes();
    test_flow();
    test_failures();
    printf("core_test failures=%d\n", failures);
    return failures != 0;
}
