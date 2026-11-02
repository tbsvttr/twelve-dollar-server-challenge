use super::*;

#[test]
fn request_capacity_stays_charged_until_reply_consumption() {
    let (tx, requests) = mpsc::sync_channel(2);
    let sender = WriteSender { tx, thread: thread::current(), bytes: Rc::new(Cell::new(0)) };
    let other_ring = sender.clone();
    for _ in 0..2 {
        assert!(sender.try_send(WriteJob {
            request: Vec::with_capacity(REQUEST_BYTES / 2 + SMALL_REQUEST), ..Default::default()
        }).is_ok());
    }
    let active = requests.try_recv().unwrap();
    // Dequeuing into the writer batch does not free the shared byte budget.
    assert!(!other_ring.available(SMALL_REQUEST + 1));
    assert!(matches!(other_ring.try_send(WriteJob {
        request: Vec::with_capacity(SMALL_REQUEST + 1), ..Default::default()
    }), Err(TrySendError::Full(_))));
    // Small buffers remain bounded by queue slots when the excess budget is full.
    assert!(other_ring.available(SMALL_REQUEST));
    assert!(other_ring.try_send(WriteJob {
        request: Vec::with_capacity(16), ..Default::default()
    }).is_ok());
    assert_eq!(sender.bytes.get(), REQUEST_BYTES);
    sender.completed(&active);
    let used = sender.bytes.get();
    // A job-count-full channel must not leak a byte reservation either.
    assert!(matches!(sender.try_send(WriteJob {
        request: Vec::with_capacity(SMALL_REQUEST + 32), ..Default::default()
    }), Err(TrySendError::Full(_))));
    assert_eq!(sender.bytes.get(), used);
    for job in requests.try_iter() { sender.completed(&job); }
    assert_eq!(sender.bytes.get(), 0);
    drop(requests);
    assert!(matches!(sender.try_send(WriteJob::default()), Err(TrySendError::Disconnected(_))));
    assert_eq!(sender.bytes.get(), 0);
}

#[test]
#[ignore = "requires a disposable seeded SQLITE_PATH and CHECK_TOKEN"]
fn responses_follow_commit_and_failed_batches_leave_no_rows() {
    let _fixture = crate::SEEDED_TEST.lock().unwrap();
    let path = std::env::temp_dir().join(format!("writer-commit-{}.db", std::process::id()));
    std::fs::copy(std::env::var("SQLITE_PATH").unwrap(), &path).unwrap();
    let body = r#"{"body":"writer commit check"}"#;
    let raw = format!(
        "POST /posts HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {}\r\nContent-Length: {}\r\n\r\n{}",
        std::env::var("CHECK_TOKEN").unwrap(),
        body.len(),
        body
    );
    let mut last_id = 0;
    for reject in [false, true] {
        let database = path.clone();
        let writer = Writer::spawn(move || {
            let mut db = db::Db::open(database.to_str().unwrap(), true);
            if reject {
                db.reject_commits();
            }
            App {
                db,
                auth: Auth::new("twelve-dollar-challenge"),
                start: Instant::now(),
            }
        })
        .unwrap();
        for fd in 0..64 {
            writer
                .sender
                .tx
                .send(WriteJob {
                    fd,
                    generation: 73,
                    request: raw.as_bytes().to_vec(),
                    ..Default::default()
                })
                .unwrap();
        }
        writer.sender.thread.unpark();
        let mut reader = db::Db::open(path.to_str().unwrap(), false);
        for fd in 0..64 {
            let job = writer
                .replies
                .as_ref()
                .unwrap()
                .recv_timeout(Duration::from_secs(30))
                .unwrap();
            assert_eq!((job.fd, job.generation), (fd, 73));
            assert_eq!(job.status, if reject { 500 } else { 201 });
            if !reject {
                let value: serde_json::Value = serde_json::from_slice(&job.body).unwrap();
                last_id = value["post"]["id"].as_i64().unwrap();
                // A separate connection must see every published row already.
                assert_eq!(reader.read(Some(last_id), &mut Vec::new()), 200);
            }
        }
        drop(writer);
        if reject {
            assert_eq!(reader.read(Some(last_id + 1), &mut Vec::new()), 404);
        }
        drop(reader);
    }
    std::fs::remove_file(path).unwrap();
}
