#ifndef GOOSE_JSON_FAST_H
#define GOOSE_JSON_FAST_H

#include "net.h"

/* Generic JSON byte primitives; they contain no application or SQL logic. */
int64_t json_plain_prefix(bytes text);
void json_append_string(bytes text, gs_rref output);

#endif
