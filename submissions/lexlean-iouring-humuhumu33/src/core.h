// Written by the certified LexLean root. The theorems about these tables are in the same module.
#define PHASE_IDLE 0
#define PHASE_READING 1
#define PHASE_COMMITTING 2
#define EVENT_REQUEST 0
#define EVENT_BATCH_END 1
#define EVENT_COMMIT_OK 2
#define EVENT_COMMIT_FAIL 3
#define ACTION_NOTHING 0
#define ACTION_BEGIN 1
#define ACTION_COMMIT 2
#define ACTION_SEND_ALL 3
#define ACTION_FAIL_ALL 4
static const uint8_t NEXT_PHASE[3][4] = {
    {1, 0, 0, 0, },
    {1, 2, 1, 1, },
    {2, 2, 0, 0, },
};
static const uint8_t ACTION_OF[3][4] = {
    {1, 0, 0, 0, },
    {0, 2, 0, 0, },
    {0, 0, 3, 4, },
};
#define METHOD_GET 0
#define METHOD_POST 1
#define METHOD_OTHER 2
#define SHAPE_FEED 0
#define SHAPE_HEALTH 1
#define SHAPE_POSTS 2
#define SHAPE_POST_ID 3
#define SHAPE_POST_LIKE 4
#define SHAPE_UNKNOWN 5
#define ROUTE_NOT_FOUND 0
#define ROUTE_FEED 1
#define ROUTE_HEALTH 2
#define ROUTE_POST 3
#define ROUTE_CREATE 4
#define ROUTE_LIKE 5
static const uint8_t ROUTE_OF[3][6] = {
    {1, 2, 0, 3, 0, 0, },
    {0, 0, 4, 0, 5, 0, },
    {0, 0, 0, 0, 0, 0, },
};
static const uint8_t ROUTE_NEEDS_TOKEN[6] = {0, 0, 0, 0, 1, 1, };
// Indexed by room, closed gate, write, held connection, most significant first.
static const uint8_t SHOULD_HOLD[16] = {
    0, 0, 0, 0, 
    0, 0, 0, 0, 
    0, 1, 0, 1, 
    0, 1, 1, 1, 
};
// Indexed by closed, over the limit, copied, timed out, most significant first.
static const uint8_t GATE_NEXT[16] = {
    0, 0, 0, 0, 
    1, 1, 1, 1, 
    1, 0, 0, 0, 
    1, 0, 0, 0, 
};
#define E_NOT_FOUND 0
#define FAILURE_ROW_0 {404, "Not Found", "not found"}
#define E_BAD_ID 1
#define FAILURE_ROW_1 {400, "Bad Request", "invalid post id"}
#define E_POST_MISSING 2
#define FAILURE_ROW_2 {404, "Not Found", "post not found"}
#define E_NO_BEARER 3
#define FAILURE_ROW_3 {401, "Unauthorized", "missing bearer token"}
#define E_BAD_TOKEN 4
#define FAILURE_ROW_4 {401, "Unauthorized", "invalid or expired token"}
#define E_BAD_PAYLOAD 5
#define FAILURE_ROW_5 {401, "Unauthorized", "invalid token payload"}
#define E_BAD_JSON 6
#define FAILURE_ROW_6 {400, "Bad Request", "malformed JSON body"}
#define E_NO_BODY 7
#define FAILURE_ROW_7 {400, "Bad Request", "body is required"}
#define E_LONG_BODY 8
#define FAILURE_ROW_8 {400, "Bad Request", "body must be at most 500 characters"}
#define E_INTERNAL 9
#define FAILURE_ROW_9 {500, "Internal Server Error", "internal server error"}
#define E_COUNT 10
#define ESCAPE_PLAIN 0
#define ESCAPE_BACKSLASH 1
#define ESCAPE_UNICODE 2
static const uint8_t ESCAPE_CLASS[256] = {
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
};
// Carried text, with no theorem: the core test checks every byte in every lane.
static inline int word_needs_escape(uint64_t word) {
    const uint64_t low7 = 0x7f7f7f7f7f7f7f7fULL;
    uint64_t quote = word ^ 0x2222222222222222ULL, slash = word ^ 0x5c5c5c5c5c5c5c5cULL, control = word & 0xe0e0e0e0e0e0e0e0ULL;
#define HAS_ZERO(x) (~((((x) & low7) + low7) | (x) | low7))
    return (HAS_ZERO(quote) | HAS_ZERO(slash) | HAS_ZERO(control)) != 0;
}
