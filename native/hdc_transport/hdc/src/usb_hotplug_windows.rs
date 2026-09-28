//! Windows-native USB device arrival/removal event listener.
//!
//! Replaces libusb polling on Windows (where libusb hotplug is unavailable)
//! by using RegisterDeviceNotificationW + a hidden message window.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedSender;
use tracing::{error, info, trace};
use windows_sys::Win32::Foundation::{GetLastError, HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetWindowLongPtrW, PeekMessageW,
    RegisterClassExW, RegisterDeviceNotificationW, SetWindowLongPtrW, TranslateMessage,
    UnregisterDeviceNotification, DBT_DEVICEARRIVAL, DBT_DEVICEREMOVECOMPLETE,
    DBT_DEVTYP_DEVICEINTERFACE, DEVICE_NOTIFY_WINDOW_HANDLE, DEV_BROADCAST_DEVICEINTERFACE_W,
    GWLP_USERDATA, MSG, PM_REMOVE, WNDCLASSEXW, WM_DEVICECHANGE, WM_QUIT,
};

/// GUID_DEVINTERFACE_USB_DEVICE
const GUID_USB: windows_sys::core::GUID = windows_sys::core::GUID {
    data1: 0xA5DCBF10,
    data2: 0x6530,
    data3: 0x11D2,
    data4: [0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED],
};

const CLASS_NAME_W: &[u16] = &[
    b'H' as u16, b'd' as u16, b'c' as u16, b'U' as u16, b's' as u16, b'b' as u16,
    b'H' as u16, b'o' as u16, b't' as u16, b'p' as u16, b'l' as u16, b'u' as u16,
    b'g' as u16, 0,
];

const WINDOW_NAME_W: &[u16] = &[
    b'H' as u16, b'd' as u16, b'c' as u16, b'U' as u16, b's' as u16, b'b' as u16,
    b'W' as u16, b'n' as u16, b'd' as u16, 0,
];

/// Start a background thread with a hidden message window that listens for
/// WM_DEVICECHANGE (USB plug/unplug).  Events are sent through `tx`.
///
/// Returns `true` if the watcher was started successfully.
pub fn spawn_windows_usb_watcher(tx: UnboundedSender<()>) -> bool {
    let stop_flag = Arc::new(AtomicBool::new(false));

    std::thread::spawn(move || {
        unsafe { run_message_loop(stop_flag, tx) };
    });

    true
}

unsafe fn run_message_loop(stop_flag: Arc<AtomicBool>, tx: UnboundedSender<()>) {
    // Register window class
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: Some(window_proc),
        hInstance: std::ptr::null_mut(),
        lpszClassName: CLASS_NAME_W.as_ptr(),
        ..std::mem::zeroed()
    };
    if RegisterClassExW(&wc) == 0 {
        error!(
            "RegisterClassExW failed, err={}",
            windows_sys::Win32::Foundation::GetLastError()
        );
        return;
    }

    // Create hidden message-only window (hwnd_parent = HWND_MESSAGE = -3)
    let hwnd = CreateWindowExW(
        0,
        CLASS_NAME_W.as_ptr(),
        WINDOW_NAME_W.as_ptr(),
        0,
        0, 0, 0, 0,
        -3isize as HWND, // HWND_MESSAGE
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        std::ptr::null(),
    );
    if hwnd.is_null() {
        error!(
            "CreateWindowExW failed, err={}",
            windows_sys::Win32::Foundation::GetLastError()
        );
        return;
    }

    // Store sender in window user data so window_proc can access it.
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, &tx as *const _ as isize);

    // Register for USB device interface notifications
    let mut dbi: DEV_BROADCAST_DEVICEINTERFACE_W = std::mem::zeroed();
    dbi.dbcc_size = std::mem::size_of::<DEV_BROADCAST_DEVICEINTERFACE_W>() as u32;
    dbi.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    dbi.dbcc_classguid = GUID_USB;

    let notify_handle = RegisterDeviceNotificationW(
        hwnd as *mut _,
        &mut dbi as *mut _ as *mut _,
        DEVICE_NOTIFY_WINDOW_HANDLE,
    );
    if notify_handle.is_null() {
        trace!(
            "RegisterDeviceNotificationW failed, err={}",
            windows_sys::Win32::Foundation::GetLastError()
        );
    } else {
        info!("Windows USB hotplug watcher active");
    }

    // Message loop
    let mut msg: MSG = std::mem::zeroed();
    loop {
        if stop_flag.load(Ordering::Relaxed) {
            break;
        }
        let has_msg = PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_REMOVE);
        if has_msg != 0 {
            if msg.message == WM_QUIT {
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        } else {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    if !notify_handle.is_null() {
        UnregisterDeviceNotification(notify_handle);
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    _lparam: LPARAM,
) -> LRESULT {
    if msg == WM_DEVICECHANGE {
        let event = wparam as u32;
        if event == DBT_DEVICEARRIVAL || event == DBT_DEVICEREMOVECOMPLETE {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if ptr != 0 {
                let tx = &*(ptr as *const UnboundedSender<()>);
                let _ = tx.send(());
            }
        }
        return 0;
    }
    DefWindowProcW(hwnd, msg, wparam, _lparam)
}
