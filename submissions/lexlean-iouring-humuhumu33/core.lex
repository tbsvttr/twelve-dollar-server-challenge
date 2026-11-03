inductive{
  name: Phase,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: idle, fields: []},
    {name: reading, fields: []},
    {name: committing, fields: []}
  ]
}

inductive{
  name: Event,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: request, fields: []},
    {name: batchEnd, fields: []},
    {name: commitOk, fields: []},
    {name: commitFail, fields: []}
  ]
}

inductive{
  name: Action,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: nothing, fields: []},
    {name: begin, fields: []},
    {name: commit, fields: []},
    {name: sendAll, fields: []},
    {name: failAll, fields: []}
  ]
}

definition{
  name: nextPhase,
  parameters: [phase : Phase, event : Event],
  result: Phase,
  body: (match phase
    | Phase.idle => (match event
      | Event.request => (ctor Phase.reading)
      | Event.batchEnd => (ctor Phase.idle)
      | Event.commitOk => (ctor Phase.idle)
      | Event.commitFail => (ctor Phase.idle))
    | Phase.reading => (match event
      | Event.request => (ctor Phase.reading)
      | Event.batchEnd => (ctor Phase.committing)
      | Event.commitOk => (ctor Phase.reading)
      | Event.commitFail => (ctor Phase.reading))
    | Phase.committing => (match event
      | Event.request => (ctor Phase.committing)
      | Event.batchEnd => (ctor Phase.committing)
      | Event.commitOk => (ctor Phase.idle)
      | Event.commitFail => (ctor Phase.idle))),
  executable: true
}

definition{
  name: actionOf,
  parameters: [phase : Phase, event : Event],
  result: Action,
  body: (match phase
    | Phase.idle => (match event
      | Event.request => (ctor Action.begin)
      | Event.batchEnd => (ctor Action.nothing)
      | Event.commitOk => (ctor Action.nothing)
      | Event.commitFail => (ctor Action.nothing))
    | Phase.reading => (match event
      | Event.request => (ctor Action.nothing)
      | Event.batchEnd => (ctor Action.commit)
      | Event.commitOk => (ctor Action.nothing)
      | Event.commitFail => (ctor Action.nothing))
    | Phase.committing => (match event
      | Event.request => (ctor Action.nothing)
      | Event.batchEnd => (ctor Action.nothing)
      | Event.commitOk => (ctor Action.sendAll)
      | Event.commitFail => (ctor Action.failAll))),
  executable: true
}

definition{
  name: sendAllowed,
  parameters: [phase : Phase, event : Event],
  result: Bool,
  body: (match (actionOf phase event)
    | Action.sendAll => (match phase
      | Phase.committing => (match event
        | Event.commitOk => true
        | Event.request => false
        | Event.batchEnd => false
        | Event.commitFail => false)
      | Phase.idle => false
      | Phase.reading => false)
    | Action.nothing => true
    | Action.begin => true
    | Action.commit => true
    | Action.failAll => true),
  executable: true
}

definition{
  name: failAllowed,
  parameters: [phase : Phase, event : Event],
  result: Bool,
  body: (match (actionOf phase event)
    | Action.failAll => (match phase
      | Phase.committing => (match event
        | Event.commitFail => true
        | Event.request => false
        | Event.batchEnd => false
        | Event.commitOk => false)
      | Phase.idle => false
      | Phase.reading => false)
    | Action.nothing => true
    | Action.begin => true
    | Action.commit => true
    | Action.sendAll => true),
  executable: true
}

definition{
  name: checkCommitting,
  parameters: [phase : Phase, next : Phase, action : Action],
  result: Bool,
  body: (match next
    | Phase.committing => (match phase
      | Phase.committing => true
      | Phase.idle => false
      | Phase.reading => (match action
        | Action.commit => true
        | Action.nothing => false
        | Action.begin => false
        | Action.sendAll => false
        | Action.failAll => false))
    | Phase.idle => true
    | Phase.reading => true),
  executable: true
}

definition{
  name: committingFollowsCommit,
  parameters: [phase : Phase, event : Event],
  result: Bool,
  body: (checkCommitting phase (nextPhase phase event) (actionOf phase event)),
  executable: true
}

theorem{
  name: send_only_after_commit,
  parameters: [phase : Phase, event : Event],
  statement: ((sendAllowed phase event) = true),
  proof: EXHAUST(phase:idle,reading,committing;event:request,batchEnd,commitOk,commitFail;actionOf,sendAllowed)
}

theorem{
  name: fail_only_after_failed_commit,
  parameters: [phase : Phase, event : Event],
  statement: ((failAllowed phase event) = true),
  proof: EXHAUST(phase:idle,reading,committing;event:request,batchEnd,commitOk,commitFail;actionOf,failAllowed)
}

theorem{
  name: committing_follows_commit,
  parameters: [phase : Phase, event : Event],
  statement: ((committingFollowsCommit phase event) = true),
  proof: EXHAUST(phase:idle,reading,committing;event:request,batchEnd,commitOk,commitFail;)
}

inductive{
  name: Method,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: get, fields: []},
    {name: post, fields: []},
    {name: other, fields: []}
  ]
}

inductive{
  name: Shape,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: feed, fields: []},
    {name: health, fields: []},
    {name: posts, fields: []},
    {name: postId, fields: []},
    {name: postLike, fields: []},
    {name: unknown, fields: []}
  ]
}

inductive{
  name: Route,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: notFound, fields: []},
    {name: feed, fields: []},
    {name: health, fields: []},
    {name: post, fields: []},
    {name: create, fields: []},
    {name: like, fields: []}
  ]
}

definition{
  name: routeOf,
  parameters: [method : Method, shape : Shape],
  result: Route,
  body: (match method
    | Method.get => (match shape
      | Shape.feed => (ctor Route.feed)
      | Shape.health => (ctor Route.health)
      | Shape.posts => (ctor Route.notFound)
      | Shape.postId => (ctor Route.post)
      | Shape.postLike => (ctor Route.notFound)
      | Shape.unknown => (ctor Route.notFound))
    | Method.post => (match shape
      | Shape.feed => (ctor Route.notFound)
      | Shape.health => (ctor Route.notFound)
      | Shape.posts => (ctor Route.create)
      | Shape.postId => (ctor Route.notFound)
      | Shape.postLike => (ctor Route.like)
      | Shape.unknown => (ctor Route.notFound))
    | Method.other => (ctor Route.notFound)),
  executable: true
}

definition{
  name: isWrite,
  parameters: [route : Route],
  result: Bool,
  body: (match route
    | Route.notFound => false
    | Route.feed => false
    | Route.health => false
    | Route.post => false
    | Route.create => true
    | Route.like => true),
  executable: true
}

definition{
  name: needsAuth,
  parameters: [route : Route],
  result: Bool,
  body: (match route
    | Route.create => true
    | Route.like => true
    | Route.notFound => false
    | Route.feed => false
    | Route.health => false
    | Route.post => false),
  executable: true
}

definition{
  name: checkWriteMethod,
  parameters: [method : Method, route : Route],
  result: Bool,
  body: (match route
    | Route.create => (match method
      | Method.post => true
      | Method.get => false
      | Method.other => false)
    | Route.like => (match method
      | Method.post => true
      | Method.get => false
      | Method.other => false)
    | Route.notFound => true
    | Route.feed => true
    | Route.health => true
    | Route.post => true),
  executable: true
}

definition{
  name: writeComesFromPost,
  parameters: [method : Method, shape : Shape],
  result: Bool,
  body: (checkWriteMethod method (routeOf method shape)),
  executable: true
}

theorem{
  name: every_write_needs_a_token,
  parameters: [route : Route],
  statement: ((isWrite route) = (needsAuth route)),
  proof: EXHAUST(route:notFound,feed,health,post,create,like;;isWrite,needsAuth)
}

theorem{
  name: only_post_writes,
  parameters: [method : Method, shape : Shape],
  statement: ((writeComesFromPost method shape) = true),
  proof: EXHAUST(method:get,post,other;shape:feed,health,posts,postId,postLike,unknown;checkWriteMethod,routeOf,writeComesFromPost)
}

theorem{
  name: unknown_methods_are_not_found,
  parameters: [shape : Shape],
  statement: ((routeOf (ctor Method.other) shape) = (ctor Route.notFound)),
  proof: simplify{definitions: [routeOf]}
}

inductive{
  name: Flag,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: yes, fields: []},
    {name: no, fields: []}
  ]
}

definition{
  name: shouldHold,
  parameters: [room : Flag, gateClosed : Flag, write : Flag, connectionHeld : Flag],
  result: Flag,
  body: (match room
    | Flag.no => (ctor Flag.no)
    | Flag.yes => (match connectionHeld
      | Flag.yes => (ctor Flag.yes)
      | Flag.no => (match gateClosed
        | Flag.yes => write
        | Flag.no => (ctor Flag.no)))),
  executable: true
}

theorem{
  name: reads_go_on_while_writes_wait,
  parameters: [room : Flag, gateClosed : Flag],
  statement: ((shouldHold room gateClosed (ctor Flag.no) (ctor Flag.no)) = (ctor Flag.no)),
  proof: EXHAUST(room:yes,no;gateClosed:yes,no;shouldHold)
}

theorem{
  name: a_held_connection_keeps_its_order,
  parameters: [gateClosed : Flag, write : Flag],
  statement: ((shouldHold (ctor Flag.yes) gateClosed write (ctor Flag.yes)) = (ctor Flag.yes)),
  proof: EXHAUST(gateClosed:yes,no;write:yes,no;shouldHold)
}

theorem{
  name: a_closed_gate_holds_writes,
  parameters: [connectionHeld : Flag],
  statement: ((shouldHold (ctor Flag.yes) (ctor Flag.yes) (ctor Flag.yes) connectionHeld) = (ctor Flag.yes)),
  proof: EXHAUST(connectionHeld:yes,no;;shouldHold)
}

theorem{
  name: an_open_gate_holds_nothing_new,
  parameters: [room : Flag, write : Flag],
  statement: ((shouldHold room (ctor Flag.no) write (ctor Flag.no)) = (ctor Flag.no)),
  proof: EXHAUST(room:yes,no;write:yes,no;shouldHold)
}

theorem{
  name: a_full_hold_queue_holds_nothing,
  parameters: [gateClosed : Flag, write : Flag, connectionHeld : Flag],
  statement: ((shouldHold (ctor Flag.no) gateClosed write connectionHeld) = (ctor Flag.no)),
  proof: EXHAUST(gateClosed:yes,no;write:yes,no;connectionHeld:yes,no;shouldHold)
}

definition{
  name: gateNext,
  parameters: [closed : Flag, overLimit : Flag, copied : Flag, timedOut : Flag],
  result: Flag,
  body: (match closed
    | Flag.no => overLimit
    | Flag.yes => (match copied
      | Flag.yes => (ctor Flag.no)
      | Flag.no => (match timedOut
        | Flag.yes => (ctor Flag.no)
        | Flag.no => (ctor Flag.yes)))),
  executable: true
}

theorem{
  name: the_gate_stays_closed_until_the_log_is_copied,
  parameters: [overLimit : Flag],
  statement: ((gateNext (ctor Flag.yes) overLimit (ctor Flag.no) (ctor Flag.no)) = (ctor Flag.yes)),
  proof: EXHAUST(overLimit:yes,no;;gateNext)
}

theorem{
  name: the_gate_closes_at_the_limit,
  parameters: [copied : Flag, timedOut : Flag],
  statement: ((gateNext (ctor Flag.no) (ctor Flag.yes) copied timedOut) = (ctor Flag.yes)),
  proof: EXHAUST(copied:yes,no;timedOut:yes,no;gateNext)
}

theorem{
  name: the_gate_opens_when_the_log_is_copied,
  parameters: [overLimit : Flag, timedOut : Flag],
  statement: ((gateNext (ctor Flag.yes) overLimit (ctor Flag.yes) timedOut) = (ctor Flag.no)),
  proof: EXHAUST(overLimit:yes,no;timedOut:yes,no;gateNext)
}

theorem{
  name: a_timeout_always_opens_the_gate,
  parameters: [overLimit : Flag, copied : Flag],
  statement: ((gateNext (ctor Flag.yes) overLimit copied (ctor Flag.yes)) = (ctor Flag.no)),
  proof: EXHAUST(overLimit:yes,no;copied:yes,no;gateNext)
}

inductive{
  name: Status,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: badRequest, fields: []},
    {name: unauthorized, fields: []},
    {name: notFound, fields: []},
    {name: serverError, fields: []}
  ]
}

inductive{
  name: Failure,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: notFound, fields: []},
    {name: badId, fields: []},
    {name: postMissing, fields: []},
    {name: noBearer, fields: []},
    {name: badToken, fields: []},
    {name: badPayload, fields: []},
    {name: badJson, fields: []},
    {name: noBody, fields: []},
    {name: longBody, fields: []},
    {name: internal, fields: []}
  ]
}

definition{
  name: statusOf,
  parameters: [failure : Failure],
  result: Status,
  body: (match failure
    | Failure.notFound => (ctor Status.notFound)
    | Failure.badId => (ctor Status.badRequest)
    | Failure.postMissing => (ctor Status.notFound)
    | Failure.noBearer => (ctor Status.unauthorized)
    | Failure.badToken => (ctor Status.unauthorized)
    | Failure.badPayload => (ctor Status.unauthorized)
    | Failure.badJson => (ctor Status.badRequest)
    | Failure.noBody => (ctor Status.badRequest)
    | Failure.longBody => (ctor Status.badRequest)
    | Failure.internal => (ctor Status.serverError)),
  executable: true
}

definition{
  name: isServerStatus,
  parameters: [status : Status],
  result: Bool,
  body: (match status
    | Status.serverError => true
    | Status.badRequest => false
    | Status.unauthorized => false
    | Status.notFound => false),
  executable: true
}

definition{
  name: isInternal,
  parameters: [failure : Failure],
  result: Bool,
  body: (match failure
    | Failure.internal => true
    | Failure.notFound => false
    | Failure.badId => false
    | Failure.postMissing => false
    | Failure.noBearer => false
    | Failure.badToken => false
    | Failure.badPayload => false
    | Failure.badJson => false
    | Failure.noBody => false
    | Failure.longBody => false),
  executable: true
}

theorem{
  name: only_an_internal_failure_is_a_server_error,
  parameters: [failure : Failure],
  statement: ((isServerStatus (statusOf failure)) = (isInternal failure)),
  proof: EXHAUST(failure:notFound,badId,postMissing,noBearer,badToken,badPayload,badJson,noBody,longBody,internal;;statusOf,isServerStatus,isInternal)
}

inductive{
  name: EscapeClass,
  type_parameters: [],
  parameters: [],
  constructors: [
    {name: plain, fields: []},
    {name: backslash, fields: []},
    {name: unicode, fields: []}
  ]
}

definition{
  name: escapeClass,
  parameters: [octet : UInt8],
  result: EscapeClass,
  body: (if (prim equal octet (34 : UInt8) : Bool) then (ctor EscapeClass.backslash) else (if (prim equal octet (92 : UInt8) : Bool) then (ctor EscapeClass.backslash) else (if (prim equal (prim bit_and octet (224 : UInt8) : UInt8) (0 : UInt8) : Bool) then (ctor EscapeClass.unicode) else (ctor EscapeClass.plain)))),
  executable: true
}

theorem{
  name: a_quote_is_escaped,
  parameters: [],
  statement: ((escapeClass (34 : UInt8)) = (ctor EscapeClass.backslash)),
  proof: reflexivity{}
}

theorem{
  name: a_backslash_is_escaped,
  parameters: [],
  statement: ((escapeClass (92 : UInt8)) = (ctor EscapeClass.backslash)),
  proof: reflexivity{}
}

theorem{
  name: the_first_control_byte_is_escaped,
  parameters: [],
  statement: ((escapeClass (0 : UInt8)) = (ctor EscapeClass.unicode)),
  proof: reflexivity{}
}

theorem{
  name: the_last_control_byte_is_escaped,
  parameters: [],
  statement: ((escapeClass (31 : UInt8)) = (ctor EscapeClass.unicode)),
  proof: reflexivity{}
}

theorem{
  name: a_space_is_plain,
  parameters: [],
  statement: ((escapeClass (32 : UInt8)) = (ctor EscapeClass.plain)),
  proof: reflexivity{}
}

theorem{
  name: the_top_byte_is_plain,
  parameters: [],
  statement: ((escapeClass (255 : UInt8)) = (ctor EscapeClass.plain)),
  proof: reflexivity{}
}

definition{
  name: cat3,
  parameters: [a : Bytes, b : Bytes, c : Bytes],
  result: Bytes,
  body: (prim append (prim append a b : Bytes) c : Bytes),
  executable: true
}

definition{
  name: cat4,
  parameters: [a : Bytes, b : Bytes, c : Bytes, d : Bytes],
  result: Bytes,
  body: (prim append (cat3 a b c) d : Bytes),
  executable: true
}

definition{
  name: define,
  parameters: [name : Bytes, value : Bytes],
  result: Bytes,
  body: (cat4 T"#define " name T" " (prim append value T"\n" : Bytes)),
  executable: true
}

definition{
  name: row2,
  parameters: [a : Bytes, b : Bytes],
  result: Bytes,
  body: (cat4 a T", " b T", "),
  executable: true
}

definition{
  name: phaseText,
  parameters: [phase : Phase],
  result: Bytes,
  body: (match phase
    | Phase.idle => T"0"
    | Phase.reading => T"1"
    | Phase.committing => T"2"),
  executable: true
}

definition{
  name: eventText,
  parameters: [event : Event],
  result: Bytes,
  body: (match event
    | Event.request => T"0"
    | Event.batchEnd => T"1"
    | Event.commitOk => T"2"
    | Event.commitFail => T"3"),
  executable: true
}

definition{
  name: actionText,
  parameters: [action : Action],
  result: Bytes,
  body: (match action
    | Action.nothing => T"0"
    | Action.begin => T"1"
    | Action.commit => T"2"
    | Action.sendAll => T"3"
    | Action.failAll => T"4"),
  executable: true
}

definition{
  name: methodText,
  parameters: [method : Method],
  result: Bytes,
  body: (match method
    | Method.get => T"0"
    | Method.post => T"1"
    | Method.other => T"2"),
  executable: true
}

definition{
  name: shapeText,
  parameters: [shape : Shape],
  result: Bytes,
  body: (match shape
    | Shape.feed => T"0"
    | Shape.health => T"1"
    | Shape.posts => T"2"
    | Shape.postId => T"3"
    | Shape.postLike => T"4"
    | Shape.unknown => T"5"),
  executable: true
}

definition{
  name: routeText,
  parameters: [route : Route],
  result: Bytes,
  body: (match route
    | Route.notFound => T"0"
    | Route.feed => T"1"
    | Route.health => T"2"
    | Route.post => T"3"
    | Route.create => T"4"
    | Route.like => T"5"),
  executable: true
}

definition{
  name: boolText,
  parameters: [value : Bool],
  result: Bytes,
  body: (if value then T"1" else T"0"),
  executable: true
}

definition{
  name: escapeText,
  parameters: [class : EscapeClass],
  result: Bytes,
  body: (match class
    | EscapeClass.plain => T"0"
    | EscapeClass.backslash => T"1"
    | EscapeClass.unicode => T"2"),
  executable: true
}

definition{
  name: batchNames,
  parameters: [],
  result: Bytes,
  body: (cat4
    (cat3 (define T"PHASE_IDLE" (phaseText (ctor Phase.idle))) (define T"PHASE_READING" (phaseText (ctor Phase.reading))) (define T"PHASE_COMMITTING" (phaseText (ctor Phase.committing))))
    (cat4 (define T"EVENT_REQUEST" (eventText (ctor Event.request))) (define T"EVENT_BATCH_END" (eventText (ctor Event.batchEnd))) (define T"EVENT_COMMIT_OK" (eventText (ctor Event.commitOk))) (define T"EVENT_COMMIT_FAIL" (eventText (ctor Event.commitFail))))
    (cat3 (define T"ACTION_NOTHING" (actionText (ctor Action.nothing))) (define T"ACTION_BEGIN" (actionText (ctor Action.begin))) (define T"ACTION_COMMIT" (actionText (ctor Action.commit))))
    (prim append (define T"ACTION_SEND_ALL" (actionText (ctor Action.sendAll))) (define T"ACTION_FAIL_ALL" (actionText (ctor Action.failAll))) : Bytes)),
  executable: true
}

definition{
  name: phaseRow,
  parameters: [phase : Phase],
  result: Bytes,
  body: (cat3 T"    {" (prim append (row2 (phaseText (nextPhase phase (ctor Event.request))) (phaseText (nextPhase phase (ctor Event.batchEnd)))) (row2 (phaseText (nextPhase phase (ctor Event.commitOk))) (phaseText (nextPhase phase (ctor Event.commitFail)))) : Bytes) T"},\n"),
  executable: true
}

definition{
  name: actionRow,
  parameters: [phase : Phase],
  result: Bytes,
  body: (cat3 T"    {" (prim append (row2 (actionText (actionOf phase (ctor Event.request))) (actionText (actionOf phase (ctor Event.batchEnd)))) (row2 (actionText (actionOf phase (ctor Event.commitOk))) (actionText (actionOf phase (ctor Event.commitFail)))) : Bytes) T"},\n"),
  executable: true
}

definition{
  name: batchTables,
  parameters: [],
  result: Bytes,
  body: (cat4
    T"static const uint8_t NEXT_PHASE[3][4] = {\n"
    (cat4 (phaseRow (ctor Phase.idle)) (phaseRow (ctor Phase.reading)) (phaseRow (ctor Phase.committing)) T"};\n")
    T"static const uint8_t ACTION_OF[3][4] = {\n"
    (cat4 (actionRow (ctor Phase.idle)) (actionRow (ctor Phase.reading)) (actionRow (ctor Phase.committing)) T"};\n")),
  executable: true
}

definition{
  name: routeNames,
  parameters: [],
  result: Bytes,
  body: (cat4
    (cat3 (define T"METHOD_GET" (methodText (ctor Method.get))) (define T"METHOD_POST" (methodText (ctor Method.post))) (define T"METHOD_OTHER" (methodText (ctor Method.other))))
    (cat3 (define T"SHAPE_FEED" (shapeText (ctor Shape.feed))) (define T"SHAPE_HEALTH" (shapeText (ctor Shape.health))) (define T"SHAPE_POSTS" (shapeText (ctor Shape.posts))))
    (cat3 (define T"SHAPE_POST_ID" (shapeText (ctor Shape.postId))) (define T"SHAPE_POST_LIKE" (shapeText (ctor Shape.postLike))) (define T"SHAPE_UNKNOWN" (shapeText (ctor Shape.unknown))))
    (cat3
      (cat3 (define T"ROUTE_NOT_FOUND" (routeText (ctor Route.notFound))) (define T"ROUTE_FEED" (routeText (ctor Route.feed))) (define T"ROUTE_HEALTH" (routeText (ctor Route.health))))
      (define T"ROUTE_POST" (routeText (ctor Route.post)))
      (prim append (define T"ROUTE_CREATE" (routeText (ctor Route.create))) (define T"ROUTE_LIKE" (routeText (ctor Route.like))) : Bytes))),
  executable: true
}

definition{
  name: routeRow,
  parameters: [method : Method],
  result: Bytes,
  body: (cat4 T"    {"
    (cat3 (row2 (routeText (routeOf method (ctor Shape.feed))) (routeText (routeOf method (ctor Shape.health)))) (row2 (routeText (routeOf method (ctor Shape.posts))) (routeText (routeOf method (ctor Shape.postId)))) (row2 (routeText (routeOf method (ctor Shape.postLike))) (routeText (routeOf method (ctor Shape.unknown)))))
    T"},"
    T"\n"),
  executable: true
}

definition{
  name: routeTables,
  parameters: [],
  result: Bytes,
  body: (cat4
    T"static const uint8_t ROUTE_OF[3][6] = {\n"
    (cat4 (routeRow (ctor Method.get)) (routeRow (ctor Method.post)) (routeRow (ctor Method.other)) T"};\n")
    T"static const uint8_t ROUTE_NEEDS_TOKEN[6] = {"
    (cat4
      (row2 (boolText (needsAuth (ctor Route.notFound))) (boolText (needsAuth (ctor Route.feed))))
      (row2 (boolText (needsAuth (ctor Route.health))) (boolText (needsAuth (ctor Route.post))))
      (row2 (boolText (needsAuth (ctor Route.create))) (boolText (needsAuth (ctor Route.like))))
      T"};\n")),
  executable: true
}

definition{
  name: flagText,
  parameters: [flag : Flag],
  result: Bytes,
  body: (match flag
    | Flag.yes => T"1"
    | Flag.no => T"0"),
  executable: true
}

definition{
  name: holdRow,
  parameters: [room : Flag, gateClosed : Flag],
  result: Bytes,
  body: (cat3 T"    "
    (prim append (row2 (flagText (shouldHold room gateClosed (ctor Flag.no) (ctor Flag.no))) (flagText (shouldHold room gateClosed (ctor Flag.no) (ctor Flag.yes)))) (row2 (flagText (shouldHold room gateClosed (ctor Flag.yes) (ctor Flag.no))) (flagText (shouldHold room gateClosed (ctor Flag.yes) (ctor Flag.yes)))) : Bytes)
    T"\n"),
  executable: true
}

definition{
  name: gateRow,
  parameters: [closed : Flag, overLimit : Flag],
  result: Bytes,
  body: (cat3 T"    "
    (prim append (row2 (flagText (gateNext closed overLimit (ctor Flag.no) (ctor Flag.no))) (flagText (gateNext closed overLimit (ctor Flag.no) (ctor Flag.yes)))) (row2 (flagText (gateNext closed overLimit (ctor Flag.yes) (ctor Flag.no))) (flagText (gateNext closed overLimit (ctor Flag.yes) (ctor Flag.yes)))) : Bytes)
    T"\n"),
  executable: true
}

definition{
  name: flowTables,
  parameters: [],
  result: Bytes,
  body: (cat4
    T"// Indexed by room, closed gate, write, held connection, most significant first.\nstatic const uint8_t SHOULD_HOLD[16] = {\n"
    (cat4 (cat4 (holdRow (ctor Flag.no) (ctor Flag.no)) (holdRow (ctor Flag.no) (ctor Flag.yes)) (holdRow (ctor Flag.yes) (ctor Flag.no)) (holdRow (ctor Flag.yes) (ctor Flag.yes))) T"};\n" T"// Indexed by closed, over the limit, copied, timed out, most significant first.\n" T"static const uint8_t GATE_NEXT[16] = {\n")
    (cat4 (gateRow (ctor Flag.no) (ctor Flag.no)) (gateRow (ctor Flag.no) (ctor Flag.yes)) (gateRow (ctor Flag.yes) (ctor Flag.no)) (gateRow (ctor Flag.yes) (ctor Flag.yes)))
    T"};\n"),
  executable: true
}

definition{
  name: statusCode,
  parameters: [status : Status],
  result: Bytes,
  body: (match status
    | Status.badRequest => T"400, \"Bad Request\""
    | Status.unauthorized => T"401, \"Unauthorized\""
    | Status.notFound => T"404, \"Not Found\""
    | Status.serverError => T"500, \"Internal Server Error\""),
  executable: true
}

definition{
  name: failureMessage,
  parameters: [failure : Failure],
  result: Bytes,
  body: (match failure
    | Failure.notFound => T"not found"
    | Failure.badId => T"invalid post id"
    | Failure.postMissing => T"post not found"
    | Failure.noBearer => T"missing bearer token"
    | Failure.badToken => T"invalid or expired token"
    | Failure.badPayload => T"invalid token payload"
    | Failure.badJson => T"malformed JSON body"
    | Failure.noBody => T"body is required"
    | Failure.longBody => T"body must be at most 500 characters"
    | Failure.internal => T"internal server error"),
  executable: true
}

definition{
  name: failureRow,
  parameters: [name : Bytes, number : Bytes, failure : Failure],
  result: Bytes,
  body: (cat4 (define name number) T"#define FAILURE_ROW_" number (cat4 T" {" (statusCode (statusOf failure)) T", \"" (cat3 (failureMessage failure) T"\"}" T"\n"))),
  executable: true
}

definition{
  name: failureTable,
  parameters: [],
  result: Bytes,
  body: (cat4
    (cat4 (failureRow T"E_NOT_FOUND" T"0" (ctor Failure.notFound)) (failureRow T"E_BAD_ID" T"1" (ctor Failure.badId)) (failureRow T"E_POST_MISSING" T"2" (ctor Failure.postMissing)) (failureRow T"E_NO_BEARER" T"3" (ctor Failure.noBearer)))
    (cat4 (failureRow T"E_BAD_TOKEN" T"4" (ctor Failure.badToken)) (failureRow T"E_BAD_PAYLOAD" T"5" (ctor Failure.badPayload)) (failureRow T"E_BAD_JSON" T"6" (ctor Failure.badJson)) (failureRow T"E_NO_BODY" T"7" (ctor Failure.noBody)))
    (prim append (failureRow T"E_LONG_BODY" T"8" (ctor Failure.longBody)) (failureRow T"E_INTERNAL" T"9" (ctor Failure.internal)) : Bytes)
    (define T"E_COUNT" T"10")),
  executable: true
}

definition{
  name: escapeNames,
  parameters: [],
  result: Bytes,
  body: (cat3
    (define T"ESCAPE_PLAIN" (escapeText (ctor EscapeClass.plain)))
    (define T"ESCAPE_BACKSLASH" (escapeText (ctor EscapeClass.backslash)))
    (define T"ESCAPE_UNICODE" (escapeText (ctor EscapeClass.unicode)))),
  executable: true
}

definition{
  name: escapeCell,
  parameters: [octet : UInt8],
  result: Bytes,
  body: (prim append (escapeText (escapeClass octet)) T"," : Bytes),
  executable: true
}

ESCAPE_ROWS

definition{
  name: wordEscapeText,
  parameters: [],
  result: Bytes,
  body: (cat4
    (cat3 T"// Carried text, with no theorem: the core test checks every byte in every lane.\n" T"static inline int word_needs_escape(uint64_t word) {\n" T"    const uint64_t low7 = 0x7f7f7f7f7f7f7f7fULL;\n")
    (cat3 T"    uint64_t quote = word ^ 0x2222222222222222ULL, slash = word ^ 0x5c5c5c5c5c5c5c5cULL, control = word & 0xe0e0e0e0e0e0e0e0ULL;\n" T"#define HAS_ZERO(x) (~((((x) & low7) + low7) | (x) | low7))\n" T"    return (HAS_ZERO(quote) | HAS_ZERO(slash) | HAS_ZERO(control)) != 0;\n")
    T"}\n"
    T""),
  executable: true
}

definition{
  name: coreHeader,
  parameters: [],
  result: Bytes,
  body: (cat4
    (cat4 T"// Written by the certified LexLean root. The theorems about these tables are in the same module.\n" (batchNames) (batchTables) (routeNames))
    (cat3 (routeTables) (flowTables) (failureTable))
    (escapeNames)
    (cat4 T"static const uint8_t ESCAPE_CLASS[256] = {\n" (escapeTable) T"};\n" (wordEscapeText))),
  executable: true
}
