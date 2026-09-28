//! USB device enumeration and async management for HDC host.
//!
//! Uses libusb1_sys directly for async bulk transfers with a dedicated event
//! thread, eliminating the Mutex bottleneck of the synchronous rusb approach.
//! Device enumeration still uses rusb for convenience.

use rusb::UsbContext;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::io::{self, Error, ErrorKind};
use std::os::raw::c_void;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{debug, info, warn, trace};

const HARMONY_CLASS: u8 = 0xFF;
const HARMONY_SUBCLASS: u8 = 0x50;
const HARMONY_PROTOCOL: u8 = 0x01;
const HARMONY_EP_NUM: u8 = 2;

#[derive(Debug, Clone)]
pub struct UsbDeviceInfo {
    pub serial_number: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub device_address: u8,
}

/// Async USB connection using libusb async API with a dedicated event thread.
/// Multiple read/write transfers can be in flight concurrently without locking.
pub struct AsyncUsbConnection {
    pub handle: *mut libusb1_sys::libusb_device_handle,
    pub interface: u8,
    pub bulk_in: u8,
    pub bulk_out: u8,
    pub max_packet_size: u16,
    context: *mut libusb1_sys::libusb_context,
    stop_events: Arc<AtomicBool>,
    _event_thread: Option<std::thread::JoinHandle<()>>,
}

// libusb device handles and contexts are safe to send across threads.
unsafe impl Send for AsyncUsbConnection {}
unsafe impl Sync for AsyncUsbConnection {}

impl Drop for AsyncUsbConnection {
    fn drop(&mut self) {
        unsafe {
            self.stop_events.store(true, Ordering::Relaxed);
            if let Some(t) = self._event_thread.take() {
                let _ = t.join();
            }
            libusb1_sys::libusb_release_interface(self.handle, self.interface as i32);
            libusb1_sys::libusb_close(self.handle);
            // NOTE: we do NOT call libusb_exit here because the context is
            // the global rusb context which outlives this connection.
        }
    }
}

impl AsyncUsbConnection {
    /// Submit an async bulk transfer and await its completion.
    ///
    /// `buf` must remain valid until the returned future resolves.
    /// For writes the caller should pass a owned or borrowed buffer that
    /// outlives the await point.
    async fn submit_transfer(
        &self,
        endpoint: u8,
        buf: &mut [u8],
        timeout_ms: u32,
    ) -> io::Result<usize> {
        let (tx, rx) = tokio::sync::oneshot::channel::<io::Result<usize>>();
        let tx = Box::into_raw(Box::new(tx)) as *mut c_void;

        let transfer = unsafe { libusb1_sys::libusb_alloc_transfer(0) };
        if transfer.is_null() {
            unsafe { drop(Box::from_raw(tx as *mut tokio::sync::oneshot::Sender<io::Result<usize>>)) };
            return Err(Error::new(ErrorKind::Other, "libusb_alloc_transfer failed"));
        }

        unsafe {
            libusb1_sys::libusb_fill_bulk_transfer(
                transfer,
                self.handle,
                endpoint,
                buf.as_mut_ptr(),
                buf.len() as i32,
                Self::transfer_callback,
                tx,
                timeout_ms,
            );

            let r = libusb1_sys::libusb_submit_transfer(transfer);
            if r != 0 {
                libusb1_sys::libusb_free_transfer(transfer);
                drop(Box::from_raw(tx as *mut tokio::sync::oneshot::Sender<io::Result<usize>>));
                return Err(Error::new(
                    ErrorKind::Other,
                    format!("libusb_submit_transfer failed: {r}"),
                ));
            }
        }

        rx.await
            .map_err(|_| Error::new(ErrorKind::Other, "USB transfer cancelled (sender dropped)"))?
    }

    extern "system" fn transfer_callback(transfer: *mut libusb1_sys::libusb_transfer) {
        unsafe {
            let tx = Box::from_raw(
                (*transfer).user_data as *mut tokio::sync::oneshot::Sender<io::Result<usize>>,
            );
            let status = (*transfer).status;
            let actual_length = (*transfer).actual_length as usize;

            let result = match status {
                0 => Ok(actual_length),
                2 => Err(Error::new(ErrorKind::TimedOut, "USB transfer timed out")),
                3 => Err(Error::new(ErrorKind::Interrupted, "USB transfer cancelled")),
                4 => Err(Error::new(ErrorKind::Other, "USB transfer stalled")),
                5 => Err(Error::new(ErrorKind::NotConnected, "USB device disconnected")),
                6 => Err(Error::new(ErrorKind::Other, "USB transfer overflow")),
                _ => Err(Error::new(
                    ErrorKind::Other,
                    format!("USB transfer failed: status={status}"),
                )),
            };

            libusb1_sys::libusb_free_transfer(transfer);
            let _ = tx.send(result);
        }
    }

    /// Read up to `buf.len()` bytes from a bulk IN endpoint.
    pub async fn read_bulk(&self, endpoint: u8, buf: &mut [u8], timeout_ms: u32) -> io::Result<usize> {
        self.submit_transfer(endpoint, buf, timeout_ms).await
    }

    /// Write all bytes in `data` to a bulk OUT endpoint.
    pub async fn write_bulk(&self, endpoint: u8, data: &[u8], timeout_ms: u32) -> io::Result<usize> {
        // Clone data into a Vec so the buffer lives long enough for the async transfer.
        let mut buf = data.to_vec();
        self.submit_transfer(endpoint, &mut buf, timeout_ms).await
    }
}

/// Enumerate connected HarmonyOS devices via USB.
pub async fn enumerate_harmony_devices() -> Vec<UsbDeviceInfo> {
    info!("usb: starting device enumeration");
    let result = tokio::task::spawn_blocking(|| {
        let mut devices = Vec::new();
        let dev_list = match rusb::devices() {
            Ok(list) => list,
            Err(e) => {
                warn!("usb: Failed to list USB devices: {e}");
                return devices;
            }
        };
        for device in dev_list.iter() {
            let desc = match device.device_descriptor() {
                Ok(d) => d,
                Err(_) => continue,
            };
            debug!("USB device: VID={:04X} PID={:04X}", desc.vendor_id(), desc.product_id());

            // Try to read serial number. If device is already open (e.g., by an
            // active session), open() may fail on Windows. Skip it - it is already
            // being managed by an existing session.
            let serial = match device.open() {
                Ok(handle) => {
                    match handle.read_serial_number_string_ascii(&desc) {
                        Ok(s) => s,
                        Err(_) => {
                            debug!("usb: failed to read serial for VID={:04X} PID={:04X}",
                                   desc.vendor_id(), desc.product_id());
                            continue;
                        }
                    }
                }
                Err(_) => {
                    debug!("usb: device already open or busy VID={:04X} PID={:04X}, skipping",
                           desc.vendor_id(), desc.product_id());
                    continue;
                }
            };

            // Check configurations for HDC interface
            let mut found = false;
            match device.active_config_descriptor().or_else(|_| device.config_descriptor(0)) {
                Ok(config) => {
                    for interface in config.interfaces() {
                        for alt in interface.descriptors() {
                            if alt.class_code() == HARMONY_CLASS
                                && alt.sub_class_code() == HARMONY_SUBCLASS
                                && alt.protocol_code() == HARMONY_PROTOCOL
                                && alt.endpoint_descriptors().count() == HARMONY_EP_NUM as usize
                            {
                                info!(
                                    "Found HarmonyOS device: serial={}, VID={:04X}, PID={:04X}",
                                    serial, desc.vendor_id(), desc.product_id()
                                );
                                devices.push(UsbDeviceInfo {
                                    serial_number: serial.clone(),
                                    vendor_id: desc.vendor_id(),
                                    product_id: desc.product_id(),
                                    device_address: device.address(),
                                });
                                found = true;
                                break;
                            }
                        }
                        if found { break; }
                    }
                }
                Err(_) => {}
            }
        }
        devices
    }).await.unwrap_or_default();

    info!("usb: enumeration complete, found {} devices", result.len());
    result
}

/// Open and claim a HarmonyOS USB device by serial number,
/// returning an async connection with a dedicated libusb event thread.
pub async fn connect_usb_device(serial: &str) -> io::Result<AsyncUsbConnection> {
    let serial = serial.to_string();
    let result = tokio::task::spawn_blocking(move || {
        let dev_list = rusb::devices()
            .map_err(|e| Error::new(ErrorKind::Other, format!("list devices failed: {e}")))?;

        for device in dev_list.iter() {
            let desc = device.device_descriptor()
                .map_err(|e| Error::new(ErrorKind::Other, format!("device descriptor failed: {e}")))?;

            let mut handle = match device.open() {
                Ok(h) => h,
                Err(_) => continue,
            };

            let dev_serial = match handle.read_serial_number_string_ascii(&desc) {
                Ok(s) => s,
                Err(_) => continue,
            };

            if dev_serial != serial {
                continue;
            }

            // Find HDC interface using active config descriptor (matches official behavior)
            let config = device.active_config_descriptor()
                .or_else(|_| device.config_descriptor(0))
                .map_err(|e| Error::new(ErrorKind::Other, format!("config descriptor failed: {e}")))?;

            let mut target_interface = None;
            let mut target_bulk_in = None;
            let mut target_bulk_out = None;

            for interface in config.interfaces() {
                for alt in interface.descriptors() {
                    if alt.class_code() == HARMONY_CLASS
                        && alt.sub_class_code() == HARMONY_SUBCLASS
                        && alt.protocol_code() == HARMONY_PROTOCOL
                    {
                        let mut bulk_in_addr = None;
                        let mut bulk_out_addr = None;

                        for ep in alt.endpoint_descriptors() {
                            if ep.transfer_type() == rusb::TransferType::Bulk {
                                if ep.direction() == rusb::Direction::In {
                                    bulk_in_addr = Some(ep.address());
                                } else {
                                    bulk_out_addr = Some(ep.address());
                                }
                            }
                        }

                        if let (Some(in_addr), Some(out_addr)) = (bulk_in_addr, bulk_out_addr) {
                            target_interface = Some(interface.number());
                            target_bulk_in = Some(in_addr);
                            target_bulk_out = Some(out_addr);
                            break;
                        }
                    }
                }
                if target_interface.is_some() { break; }
            }

            if let (Some(iface_num), Some(in_addr), Some(out_addr)) = (target_interface, target_bulk_in, target_bulk_out) {
                info!("Claiming interface {iface_num} for device {serial}, Bulk IN={in_addr}, Bulk OUT={out_addr}");
                handle.claim_interface(iface_num)
                    .map_err(|e| Error::new(ErrorKind::Other, format!("claim interface failed: {e}")))?;

                let max_packet_size = config.interfaces()
                    .flat_map(|i| i.descriptors())
                    .flat_map(|a| a.endpoint_descriptors())
                    .find(|e| e.address() == out_addr)
                    .map(|e| e.max_packet_size())
                    .unwrap_or(512);

                // Get raw pointer for async transfers, then prevent rusb from
                // auto-releasing interfaces or closing the handle.
                let raw_handle = handle.as_raw();
                let raw_context = rusb::GlobalContext::default().as_raw();
                std::mem::forget(handle);

                let stop_events = Arc::new(AtomicBool::new(false));
                let stop_clone = stop_events.clone();
                let ctx_usize = raw_context as usize;
                let event_thread = std::thread::spawn(move || {
                    let ctx = ctx_usize as *mut libusb1_sys::libusb_context;
                    while !stop_clone.load(Ordering::Relaxed) {
                        let mut tv = libc::timeval {
                            tv_sec: 0,
                            tv_usec: 100_000,
                        };
                        unsafe {
                            libusb1_sys::libusb_handle_events_timeout_completed(
                                ctx,
                                &mut tv,
                                std::ptr::null_mut(),
                            );
                        }
                    }
                });

                return Ok(AsyncUsbConnection {
                    handle: raw_handle,
                    interface: iface_num,
                    bulk_in: in_addr,
                    bulk_out: out_addr,
                    max_packet_size,
                    context: raw_context,
                    stop_events,
                    _event_thread: Some(event_thread),
                });
            }

            return Err(Error::new(ErrorKind::NotFound, "No matching interface found on device"));
        }

        Err(Error::new(ErrorKind::NotFound, "USB device not found"))
    }).await.map_err(|e| Error::new(ErrorKind::Other, format!("spawn blocking failed: {e}")))?;

    result
}

/// Spawn a libusb hotplug watcher that notifies over a channel whenever any
/// USB device is connected or disconnected.
///
/// Returns `Some(receiver)` if the platform supports libusb hotplug,
/// or `None` if hotplug is unavailable (caller should fall back to polling).
pub fn spawn_hotplug_watcher() -> Option<mpsc::Receiver<()>> {
    if !rusb::has_hotplug() {
        info!("libusb hotplug not supported on this platform");
        return None;
    }

    let (tx, rx) = mpsc::channel(16);
    let stop_flag = Arc::new(AtomicBool::new(false));
    let stop_clone = stop_flag.clone();

    struct Handler {
        tx: mpsc::Sender<()>,
    }

    impl<T: rusb::UsbContext> rusb::Hotplug<T> for Handler {
        fn device_arrived(&mut self, _device: rusb::Device<T>) {
            trace!("libusb hotplug: device arrived");
            let _ = self.tx.try_send(());
        }
        fn device_left(&mut self, _device: rusb::Device<T>) {
            trace!("libusb hotplug: device left");
            let _ = self.tx.try_send(());
        }
    }

    std::thread::spawn(move || {
        let context = match rusb::Context::new() {
            Ok(ctx) => ctx,
            Err(e) => {
                warn!("Failed to create rusb context for hotplug: {e}");
                return;
            }
        };

        let handler = Handler { tx };
        let _reg: rusb::Registration<rusb::Context> = match rusb::HotplugBuilder::new()
            .enumerate(true)
            .register(&context, Box::new(handler))
        {
            Ok(r) => r,
            Err(e) => {
                warn!("Failed to register hotplug callback: {e}");
                return;
            }
        };

        info!("libusb hotplug watcher started");

        while !stop_clone.load(Ordering::Relaxed) {
            match context.handle_events(Some(Duration::from_millis(500))) {
                Ok(_) => {}
                Err(rusb::Error::Interrupted) => {}
                Err(e) => {
                    warn!("Hotplug event handling error: {e}");
                }
            }
        }

        info!("libusb hotplug watcher stopped");
        // `_reg` is dropped here, which deregisters the callback.
    });

    Some(rx)
}
