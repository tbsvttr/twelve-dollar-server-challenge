use super::*;

fn assert_rollback(events: &[bool], close: bool) {
    let mut output = Buffer::default();
    response(200, b"previous committed reply", false, &mut output);
    let mut expected = Buffer::default();
    expected.extend(output.bytes());
    let start = output.len;
    let count = events.iter().filter(|&&interim| !interim).count() as u32;
    let body = br#"{"error":"internal server error"}"#;
    let mut completed = 0;
    for &interim in events {
        if interim {
            output.extend(b"HTTP/1.1 100 Continue\r\n\r\n");
            expected.extend(b"HTTP/1.1 100 Continue\r\n\r\n");
        } else {
            completed += 1;
            // Response-looking bytes inside a body must not become an interim.
            response(201, b"HTTP/1.1 100 Continue\r\n\r\n", false, &mut output);
            response(500, body, close && completed == count, &mut expected);
        }
    }
    Pending {
        fd: 0,
        generation: 0,
        start,
        count,
        interim: events.contains(&true),
    }
    .rollback(&mut output, close, body);
    assert_eq!(output.bytes(), expected.bytes());
}

#[test]
fn failed_batch_preserves_interim_positions() {
    for events in [
        &[true, false][..],
        &[false, true][..],
        &[false, true, false][..],
        &[true, false, true, false, true][..],
        &[true][..],
        &[false, false][..],
        &[][..],
    ] {
        assert_rollback(events, false);
        assert_rollback(events, true);
    }
}

#[test]
fn failed_send_discards_tentative_responses() {
    for start in [0, 123] {
        let mut output = Buffer::default();
        Pending {
            fd: 0,
            generation: 0,
            start,
            count: 1,
            interim: true,
        }
        .rollback(&mut output, true, b"error");
        assert!(output.bytes().is_empty());
    }
}

#[test]
#[ignore = "requires a seeded SQLITE_PATH and Linux io_uring"]
fn failed_commit_preserves_continue_order_and_rolls_back_writes() {
    use crate::{Auth, Engine, Hmac, Mac, Sha256, URL_SAFE_NO_PAD, db};

    let _fixture = crate::SEEDED_TEST.lock().unwrap();
    let fixture = std::env::temp_dir().join(format!("uring-commit-{}.db", std::process::id()));
    std::fs::copy(std::env::var("SQLITE_PATH").unwrap(), &fixture).unwrap();
    let mut app = App {
        db: db::Db::open(fixture.to_str().unwrap(), true),
        auth: Auth::new("twelve-dollar-challenge"),
        start: Instant::now(),
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut worker = Worker::new(listener.as_raw_fd(), 4096).unwrap();
    // A previous send keeps this batch buffered so its encoded output can be
    // inspected without submitting socket I/O during the deterministic test.
    let mut client = Client {
        state: LIVE | SENDING,
        ..Default::default()
    };
    response(200, b"committed prefix", false, &mut client.output);
    let mut expected = Buffer::default();
    expected.extend(client.output.bytes());
    worker.clients.push(client);

    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256"}"#);
    let payload = URL_SAFE_NO_PAD.encode(br#"{"sub":"1","username":"review","exp":4102444800}"#);
    let signed = format!("{header}.{payload}");
    let mut mac = Hmac::<Sha256>::new_from_slice(b"twelve-dollar-challenge").unwrap();
    mac.update(signed.as_bytes());
    let token = format!(
        "{signed}.{}",
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    );
    let body = br#"{"body":"failed commit"}"#;
    let headers = format!(
        "POST /posts HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {token}\r\nExpect: 100-continue\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    for _ in 0..2 {
        worker.process(0, headers.as_bytes(), &mut app);
        worker.process(0, body, &mut app);
        expected.extend(b"HTTP/1.1 100 Continue\r\n\r\n");
        response(
            500,
            br#"{"error":"internal server error"}"#,
            false,
            &mut expected,
        );
    }
    let id = serde_json::from_slice::<serde_json::Value>(&worker.body).unwrap()["post"]["id"]
        .as_i64()
        .unwrap();
    worker.process(0, headers.as_bytes(), &mut app);
    expected.extend(b"HTTP/1.1 100 Continue\r\n\r\n");
    app.db.reject_commits();
    let committed = app.db.commit();
    assert!(!committed);
    worker.flush(committed);
    assert_eq!(worker.clients[0].output.bytes(), expected.bytes());
    drop(worker);
    drop(app);
    let mut reopened = db::Db::open(fixture.to_str().unwrap(), false);
    assert_eq!(reopened.read(Some(id), &mut Vec::new()), 404);
    drop(reopened);
    std::fs::remove_file(fixture).unwrap();
}

#[test]
#[ignore = "requires a seeded SQLITE_PATH and Linux io_uring"]
fn held_write_survives_eof_and_resumes_once() {
    let _fixture = crate::SEEDED_TEST.lock().unwrap();
    let fixture = std::env::temp_dir().join(format!("held-eof-{}.db", std::process::id()));
    std::fs::copy(std::env::var("SQLITE_PATH").unwrap(), &fixture).unwrap();
    {
        let mut app = App {
            db: crate::db::Db::open(fixture.to_str().unwrap(), true),
            auth: crate::Auth::new("twelve-dollar-challenge"),
            start: Instant::now(),
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut w = Worker::new(listener.as_raw_fd(), 4096).unwrap();
        w.clients.push(Client { state: LIVE, ..Default::default() });
        let body = r#"{"body":"held"}"#;
        let request = format!("POST /posts HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {}\r\nContent-Length: {}\r\n\r\n{}",
            std::env::var("CHECK_TOKEN").unwrap(), body.len(), body);
        app.db.hold_writes_for_test(true);
        w.process(0, request.as_bytes(), &mut app);
        w.on_recv(0, 0, 0, 0, &mut app);
        assert_eq!(w.held.len(), 1);
        for _ in 0..3 { w.tick(&mut app); }
        assert!(w.ready.is_empty());
        assert!(!app.db.transaction);
        assert_eq!(w.clients[0].input.bytes(), request.as_bytes());
        assert_ne!(w.clients[0].state & EOF, 0);
        app.db.hold_writes_for_test(false);
        w.tick(&mut app);
        assert!(app.db.commit());
        assert!(w.held.is_empty());
        assert!(w.clients[0].input.bytes().is_empty());
        assert_ne!(w.clients[0].state & CLOSING, 0);
        let output = w.clients[0].output.bytes();
        assert!(output.starts_with(b"HTTP/1.1 201 Created\r\n"));
        assert_eq!(w.pending[0].count, 1);
        let at = output.windows(4).position(|s| s == b"\r\n\r\n").unwrap() + 4;
        let post: serde_json::Value = serde_json::from_slice(&output[at..]).unwrap();
        let mut out = Vec::new();
        assert_eq!(app.db.read(post["post"]["id"].as_i64(), &mut out), 200);
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&out).unwrap()["post"]["body"], "held");
    }
    std::fs::remove_file(fixture).unwrap();
}

#[test]
#[ignore = "requires Linux io_uring"]
fn writer_replies_preserve_eof_and_reject_reused_slots() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut worker = Worker::new(listener.as_raw_fd(), 4096).unwrap();
    worker.clients.push(Client { generation: 2, state: LIVE | WRITING | EOF, ..Default::default() });
    worker.written(WriteJob { fd: 0, generation: 1, status: 201, body: b"stale".to_vec(), ..Default::default() });
    assert!(worker.clients[0].output.bytes().is_empty());
    assert_ne!(worker.clients[0].state & WRITING, 0);
    worker.written(WriteJob { fd: 0, generation: 2, status: 201, body: b"committed".to_vec(), ..Default::default() });
    assert_eq!(worker.clients[0].state & WRITING, 0);
    assert_ne!(worker.clients[0].state & CLOSING, 0);
    assert!(worker.clients[0].output.bytes().ends_with(b"committed"));
    assert_eq!(worker.pending[0].count, 1);

    worker.clients[0] = Client { generation: 3, state: LIVE | WRITING, ..Default::default() };
    worker.clients[0].input.extend(b"GET /feed HTTP/1.1\r\nHost: test\r\n\r\n");
    worker.pending.clear();
    worker.written(WriteJob { fd: 0, generation: 3, status: 201, ..Default::default() });
    assert_eq!(worker.ready.pop_front(), Some((0, 3)));
    assert_eq!(worker.clients[0].state & (WRITING | CLOSING), 0);
}

#[test]
#[ignore = "requires a seeded SQLITE_PATH, CHECK_TOKEN and Linux io_uring"]
fn queued_write_survives_receive_eof() {
    let _fixture = crate::SEEDED_TEST.lock().unwrap();
    let path = std::env::temp_dir().join(format!("writer-eof-{}.db", std::process::id()));
    std::fs::copy(std::env::var("SQLITE_PATH").unwrap(), &path).unwrap();
    {
        let mut app = App {
            db: crate::db::Db::open(path.to_str().unwrap(), true),
            auth: crate::Auth::new("twelve-dollar-challenge"),
            start: Instant::now(),
        };
        let writer = Writer::new(path.to_str().unwrap().to_owned(),
            "twelve-dollar-challenge".to_owned(), app.start, true).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut w = Worker::new(listener.as_raw_fd(), 4096).unwrap();
        w.writer = Some(writer.sender.clone());
        w.clients.push(Client { state: LIVE | RECEIVING, ..Default::default() });
        let body = r#"{"body":"async EOF"}"#;
        let raw = format!("POST /posts HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {}\r\nContent-Length: {}\r\n\r\n{}",
            std::env::var("CHECK_TOKEN").unwrap(), body.len(), body);
        w.process(0, raw.as_bytes(), &mut app);
        assert_ne!(w.clients[0].state & WRITING, 0);
        assert!(w.clients[0].input.bytes().is_empty());
        w.on_recv(0, 0, 0, 0, &mut app);
        assert_ne!(w.clients[0].state & EOF, 0);
        assert_eq!(w.clients[0].state & CLOSING, 0);
        assert!(w.clients[0].output.bytes().is_empty());
        let job = writer.replies.as_ref().unwrap().recv_timeout(Duration::from_secs(30)).unwrap();
        assert_eq!(job.status, 201);
        let value: serde_json::Value = serde_json::from_slice(&job.body).unwrap();
        let id = value["post"]["id"].as_i64().unwrap();
        w.written(job);
        assert_ne!(w.clients[0].state & CLOSING, 0);
        assert_eq!(w.clients[0].state & WRITING, 0);
        assert_eq!(w.pending[0].count, 1);
        assert!(w.clients[0].output.bytes().starts_with(b"HTTP/1.1 201 Created\r\n"));
        assert_eq!(app.db.read(Some(id), &mut Vec::new()), 200);
    }
    std::fs::remove_file(path).unwrap();
}

#[test]
#[ignore = "requires a seeded SQLITE_PATH and Linux io_uring"]
fn closing_eof_releases_pipelined_input_without_idle_sweep() {
    let _fixture = crate::SEEDED_TEST.lock().unwrap();
    let mut app = App {
        db: crate::db::Db::open(&std::env::var("SQLITE_PATH").unwrap(), true),
        auth: crate::Auth::new("twelve-dollar-challenge"),
        start: Instant::now(),
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut worker = Worker::new(listener.as_raw_fd(), 4096).unwrap();
    let mut client = Client {
        generation: 7, state: LIVE | CLOSING | RECEIVING | SHUT, ..Default::default()
    };
    client.input.extend(b"GET /feed HTTP/1.1\r\nHost: test\r\n\r\n");
    worker.clients.push(client);
    worker.open = 1;
    worker.on_recv(0, 7, 0, 0, &mut app);
    assert_eq!(worker.open, 0);
    assert_eq!(worker.clients[0].state, 0);
    assert_eq!(worker.clients[0].generation, 8);
    assert_eq!(worker.clients[0].input.cap, 0);
    assert!(worker.ready.is_empty());
}
