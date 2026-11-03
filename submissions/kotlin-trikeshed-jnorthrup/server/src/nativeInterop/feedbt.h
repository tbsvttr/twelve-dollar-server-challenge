/* feedbt.h: the B-tree read plans of feedbt.c (built into libsqlite3.a with the amalgamation). */
#ifndef FEEDBT_H
#define FEEDBT_H

/* 1 when the schema is the one the plans read (else every call returns -1). Call once, after the connection is open. */
int feedbt_init(sqlite3 *db);

/* GET /feed's JSON at dst: the bytes written; -1 when the SQL path must answer; below -1, minus the room to call again with. */
int feedbt_feed(char *dst, int cap);

/* GET /posts/:id's JSON at dst: the bytes written; 0 when there is no such post; -1 and below as feedbt_feed. */
int feedbt_post(long long id, char *dst, int cap);

/* Ends the wake's read transaction and closes its cursors (a no-op when none is held). Call at the end of each wake and
 * before any SQL statement steps on the connection. */
void feedbt_release(void);

#endif
