//! Parallel, bounded batches over the device-verified TCP discovery transport.
use std::net::Ipv4Addr;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Mutex,
};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct Host {
    pub ip: Ipv4Addr,
    pub next: u32,
    pub checked: usize,
    pub timed_out: usize,
    pub found: Option<u16>,
    pub open_ports: Vec<u16>,
}
impl Host {
    pub fn new(ip: Ipv4Addr, next: u32) -> Self {
        Self {
            ip,
            next,
            checked: 0,
            timed_out: 0,
            found: None,
            open_ports: Vec::new(),
        }
    }
}
#[derive(Clone, Default)]
pub struct Progress {
    pub checked: usize,
    pub covered: usize,
    pub total: usize,
    pub complete: bool,
    pub timed_out: usize,
    pub peak_sockets: usize,
    pub socket_limit: usize,
    pub error: i32,
    pub created: usize,
    pub elapsed_ms: u128,
    pub tcp_open: usize,
    pub protocol_failures: usize,
}
fn capacity(soft_limit: usize) -> usize {
    soft_limit
        .saturating_sub(192)
        .saturating_mul(3)
        .saturating_div(4)
        .min(2048)
}
pub fn socket_limit() -> usize {
    #[cfg(unix)]
    {
        let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
        if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
            capacity(limit.rlim_cur as usize)
        } else {
            256
        }
    }
    #[cfg(not(unix))]
    {
        0
    }
}
pub fn combined(parts: &[Progress]) -> Progress {
    Progress {
        checked: parts.iter().map(|p| p.checked).sum(),
        covered: parts.iter().map(|p| p.covered).sum(),
        total: parts.iter().map(|p| p.total).sum(),
        complete: !parts.is_empty() && parts.iter().all(|p| p.complete),
        timed_out: parts.iter().map(|p| p.timed_out).sum(),
        peak_sockets: parts.iter().map(|p| p.peak_sockets).sum(),
        socket_limit: parts.iter().map(|p| p.socket_limit).sum(),
        error: parts
            .iter()
            .find(|p| p.error != 0)
            .map(|p| p.error)
            .unwrap_or(0),
        created: parts.iter().map(|p| p.created).sum(),
        tcp_open: parts.iter().map(|p| p.tcp_open).sum(),
        protocol_failures: parts.iter().map(|p| p.protocol_failures).sum(),
        elapsed_ms: parts.iter().map(|p| p.elapsed_ms).max().unwrap_or(0),
        ..Progress::default()
    }
}
fn progress(hosts: &[Host], ports: usize, peak: usize, limit: usize, error: i32) -> Progress {
    Progress {
        checked: hosts.iter().map(|host| host.checked).sum(),
        covered: hosts
            .iter()
            .map(|host| {
                if host.found.is_some() {
                    ports
                } else {
                    host.checked
                }
            })
            .sum(),
        total: hosts.len() * ports,
        complete: !hosts.is_empty()
            && hosts
                .iter()
                .all(|host| host.found.is_some() || host.checked == ports),
        timed_out: hosts.iter().map(|host| host.timed_out).sum(),
        peak_sockets: peak,
        socket_limit: limit,
        error,
        ..Progress::default()
    }
}
fn job_range(
    job: usize,
    hosts: usize,
    ports: usize,
    slots: usize,
) -> Option<(usize, usize, usize)> {
    if hosts == 0 || slots == 0 {
        return None;
    }
    let offset = (job / hosts).checked_mul(slots)?;
    if offset >= ports {
        return None;
    }
    Some((job % hosts, offset, (ports - offset).min(slots)))
}

/// Every lane pulls the next host/range from the same queue. A fast host can
/// never leave its socket allocation idle while a slower lane still has work.
pub fn run_parallel(
    hosts: &mut [Host],
    cancel: &AtomicBool,
    deadline: Instant,
    first: u16,
    last: u16,
    found: impl Fn(Ipv4Addr, u16) + Sync,
    report: impl Fn(&Progress) + Sync,
) -> Progress {
    let started = Instant::now();
    let ports = last as usize + 1 - first as usize;
    // Lanes own port ranges, not hosts. A selected-IP lookup must be able to
    // use the same bounded socket budget as a LAN-wide lookup.
    let workers = ports.div_ceil(256).clamp(1, 8);
    let slots = (socket_limit() / workers).min(256);
    if hosts.is_empty() || slots < 16 {
        return progress(hosts, ports, 0, slots, 0);
    }
    let count = hosts.len();
    let waves = ports.div_ceil(slots);
    let jobs = AtomicUsize::new(0);
    let bases: Vec<_> = hosts.iter().map(|host| host.next).collect();
    let state = Mutex::new((hosts.to_vec(), vec![vec![false; waves]; count]));
    let results = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..workers)
            .map(|_| {
                scope.spawn(|| {
                    #[cfg(any(target_os = "linux", target_env = "ohos"))]
                    unsafe {
                        libc::setpriority(libc::PRIO_PROCESS, 0, 8);
                    }
                    let mut result = Progress {
                        socket_limit: slots,
                        ..Progress::default()
                    };
                    while !cancel.load(Ordering::Relaxed) && Instant::now() < deadline {
                        let job = jobs.fetch_add(1, Ordering::Relaxed);
                        let Some((index, offset, size)) = job_range(job, count, ports, slots)
                        else {
                            break;
                        };
                        let ip = {
                            let state = state.lock().unwrap();
                            if state.0[index].found.is_some() {
                                continue;
                            }
                            state.0[index].ip
                        };
                        let targets: Vec<_> = (offset..offset + size)
                            .map(|offset| {
                                (
                                    ip,
                                    (first as u32
                                        + (bases[index] - first as u32 + offset as u32)
                                            % ports as u32)
                                        as u16,
                                )
                            })
                            .collect();
                        let batch = super::lan_scan::connect_targets_capacity(
                            &targets,
                            cancel,
                            deadline,
                            Duration::from_millis(120),
                            slots,
                        );
                        result.created += batch.attempted;
                        result.peak_sockets = result.peak_sockets.max(batch.peak);
                        result.tcp_open += batch.streams.len();
                        for (ip, port, mut stream) in batch.streams {
                            if cancel.load(Ordering::Relaxed) || Instant::now() >= deadline {
                                break;
                            }
                            if state.lock().unwrap().0[index].found.is_some() {
                                break;
                            }
                            {
                                let mut state=state.lock().unwrap();
                                let candidates=&mut state.0[index].open_ports;
                                if candidates.len()<8&&!candidates.contains(&port){candidates.push(port);}
                            }
                            if super::lan_scan::verify_wait(
                                &mut stream,
                                ip,
                                port,
                                cancel,
                                deadline,
                                Duration::from_millis(500),
                            ) {
                                let publish = {
                                    let mut state = state.lock().unwrap();
                                    let publish = state.0[index].found.is_none();
                                    state.0[index].found = Some(port);
                                    publish
                                };
                                if publish {
                                    found(ip, port);
                                }
                                break;
                            } else {
                                result.protocol_failures += 1;
                            }
                        }
                        {
                            let mut state = state.lock().unwrap();
                            if batch.complete {
                                state.0[index].checked += size;
                                state.0[index].timed_out += batch.timed_out;
                                state.1[index][offset / slots] = true;
                            }
                            report(&progress(&state.0, ports, 0, slots * workers, result.error));
                        }
                        if !batch.complete {
                            result.error = batch.error;
                            break;
                        }
                    }
                    result
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|handle| {
                handle.join().unwrap_or_else(|_| Progress {
                    error: -1,
                    ..Progress::default()
                })
            })
            .collect::<Vec<_>>()
    });
    let (rows, completed) = state.into_inner().unwrap();
    for (index, (host, row)) in hosts.iter_mut().zip(rows).enumerate() {
        *host = row;
        let prefix = completed[index]
            .iter()
            .position(|complete| !*complete)
            .unwrap_or(waves);
        host.next = first as u32
            + (bases[index] - first as u32 + (prefix * slots).min(ports) as u32) % ports as u32;
    }
    let stats = combined(&results);
    let mut result = progress(
        hosts,
        ports,
        stats.peak_sockets,
        stats.socket_limit,
        stats.error,
    );
    result.created = stats.created;
    result.tcp_open = stats.tcp_open;
    result.protocol_failures = stats.protocol_failures;
    result.elapsed_ms = started.elapsed().as_millis();
    report(&result);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use hdc_protocol::config::{get_version, HdcCommand, TaskMessage, HANDSHAKE_MESSAGE};
    use hdc_protocol::serializer::{
        concat_pack, unpack_payload_head, unpack_task_message, HdcDeserialize, HdcSerialize,
        SessionHandShake, HEAD_SIZE,
    };
    use std::io::{Read, Write};
    #[test]
    fn capacity_reserves_app_descriptors_and_is_bounded() {
        assert_eq!(capacity(128), 0);
        assert_eq!(capacity(1024), 624);
        assert_eq!(capacity(65535), 2048);
    }
    #[test]
    fn shared_queue_covers_every_host_and_boundary_without_overlap() {
        let mut coverage = vec![vec![0u8; 55536]; 14];
        let mut job = 0;
        while let Some((host, offset, count)) = job_range(job, 14, 55536, 2048) {
            for value in &mut coverage[host][offset..offset + count] {
                *value += 1;
            }
            job += 1;
        }
        assert!(coverage.iter().flatten().all(|value| *value == 1));
        assert!(job_range(0, 0, 55536, 2048).is_none());
    }
    #[test]
    fn coverage_distinguishes_a_found_device_from_an_unfinished_host() {
        let mut hosts = vec![
            Host::new(Ipv4Addr::LOCALHOST, 10000),
            Host::new(Ipv4Addr::LOCALHOST, 10000),
        ];
        hosts[0].found = Some(65535);
        hosts[1].checked = 100;
        let result = progress(&hosts, 55536, 64, 128, 0);
        assert_eq!(result.covered, 55636);
        assert!(!result.complete);
        hosts[1].checked = 55536;
        assert!(progress(&hosts, 55536, 0, 128, 0).complete);
    }
    #[test]
    fn rolling_sweep_finds_a_device_beside_a_stalled_service_without_authenticating() {
        // Reserve both ports: a broad localhost sweep would hit listeners from
        // parallel tests and make a heartbeat-only test receive our greeting.
        let (listener, stalled) = (0..32)
            .find_map(|_| {
                let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
                let port = listener.local_addr().ok()?.port();
                let stalled =
                    std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port.checked_sub(1)?))
                        .ok()?;
                Some((listener, stalled))
            })
            .expect("two reserved adjacent test ports");
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut head = [0; HEAD_SIZE];
            stream.read_exact(&mut head).unwrap();
            let header = unpack_payload_head(&head).unwrap();
            let mut frame = head.to_vec();
            frame.resize(
                HEAD_SIZE + header.head_size as usize + header.data_size as usize,
                0,
            );
            stream.read_exact(&mut frame[HEAD_SIZE..]).unwrap();
            let request = unpack_task_message(&frame).unwrap();
            let hs = SessionHandShake::deserialize(&request.payload).unwrap();
            assert_eq!(hs.auth_type, 0);
            assert!(hs.buf.is_empty());
            let reply = SessionHandShake {
                banner: HANDSHAKE_MESSAGE.into(),
                auth_type: 2,
                session_id: 1,
                connect_key: String::new(),
                buf: "challenge".into(),
                version: get_version(),
            };
            stream
                .write_all(&concat_pack(&TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: reply.serialize(),
                }))
                .unwrap();
        });
        let first = stalled.local_addr().unwrap().port();
        let mut hosts = vec![Host::new(Ipv4Addr::LOCALHOST, first as u32)];
        let endpoints = Mutex::new(Vec::new());
        let result = run_parallel(
            &mut hosts,
            &AtomicBool::new(false),
            Instant::now() + Duration::from_secs(5),
            first,
            port,
            |ip, port| endpoints.lock().unwrap().push((ip, port)),
            |_| {},
        );
        server.join().unwrap();
        drop(stalled);
        assert_eq!(
            endpoints.into_inner().unwrap(),
            vec![(Ipv4Addr::LOCALHOST, port)]
        );
        assert!(result.complete);
        assert!(result.peak_sockets <= result.socket_limit);
    }
    #[test]
    fn cancellation_does_not_become_a_complete_scan() {
        let mut hosts = vec![Host::new(Ipv4Addr::LOCALHOST, 10000)];
        let cancel = AtomicBool::new(true);
        let start = Instant::now();
        let result = run_parallel(
            &mut hosts,
            &cancel,
            start + Duration::from_secs(30),
            10000,
            65535,
            |_, _| panic!("cancelled"),
            |_| {},
        );
        assert!(!result.complete);
        assert_eq!(result.checked, 0);
        assert!(start.elapsed() < Duration::from_millis(50));
    }
}
