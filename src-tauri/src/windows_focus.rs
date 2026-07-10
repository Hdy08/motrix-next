use windows_sys::Win32::{
    Foundation::HWND,
    System::Threading::{AttachThreadInput, GetCurrentThreadId},
    UI::WindowsAndMessaging::{
        BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsIconic,
        SetForegroundWindow, ShowWindowAsync, SW_RESTORE, SW_SHOW,
    },
};

pub fn force_foreground_window(hwnd: HWND, source: &str) -> bool {
    if hwnd.is_null() {
        log::warn!("windows-focus:foreground-failed source={source} reason=null-hwnd");
        return false;
    }

    let foreground = unsafe { GetForegroundWindow() };
    let current_thread = unsafe { GetCurrentThreadId() };
    let foreground_thread = if foreground.is_null() {
        0
    } else {
        unsafe { GetWindowThreadProcessId(foreground, std::ptr::null_mut()) }
    };
    let attached = current_thread != foreground_thread
        && foreground_thread != 0
        && unsafe { AttachThreadInput(current_thread, foreground_thread, 1) != 0 };

    let show_command = if unsafe { IsIconic(hwnd) != 0 } {
        SW_RESTORE
    } else {
        SW_SHOW
    };
    let _ = unsafe { ShowWindowAsync(hwnd, show_command) };
    let _ = unsafe { BringWindowToTop(hwnd) };
    let _ = unsafe { SetForegroundWindow(hwnd) };

    if attached {
        unsafe {
            AttachThreadInput(current_thread, foreground_thread, 0);
        }
    }

    let activated = unsafe { GetForegroundWindow() } == hwnd;
    log::debug!("windows-focus:foreground source={source} activated={activated}");
    activated
}
