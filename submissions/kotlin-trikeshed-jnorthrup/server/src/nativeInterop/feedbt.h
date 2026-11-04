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

/* Starts the checkpoint thread: a second connection to path (VFS unix-excl, as the loop's connection db) that runs a
 * PASSIVE checkpoint every ms milliseconds, so no checkpoint and no fsync runs on the loop thread (db sets
 * wal_autocheckpoint=0). Also installs db's wal hook for feedbt_wal_ready. 0 when running; below 0 when the connection or
 * the thread could not start. */
int feedbt_checkpointer(sqlite3 *db, const char *path, int ms);

/* 1 when the loop's next write batch may begin; 0 while the WAL is past its gate and not yet fully copied, so the batch
 * waits (reads go on) and its BEGIN then starts the log over. */
int feedbt_wal_ready(void);

#endif
