use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use windows_sys::Win32::{
    Foundation::{BOOL, HWND, LPARAM},
    System::Threading::{AttachThreadInput, GetCurrentThreadId},
    UI::WindowsAndMessaging::{
        AllowSetForegroundWindow, BringWindowToTop, EnumWindows, GetClassNameW,
        GetForegroundWindow, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
        SetForegroundWindow, SetWindowPos, ShowWindowAsync, SwitchToThisWindow, HWND_NOTOPMOST,
        HWND_TOPMOST, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_RESTORE, SW_SHOW,
    },
};

const ASFW_ANY: u32 = u32::MAX;
const EXPLORER_FOCUS_ATTEMPTS: usize = 10;
const EXPLORER_FOCUS_RETRY_DELAY: Duration = Duration::from_millis(80);

pub fn allow_set_foreground_window_any(source: &str) -> bool {
    let ok = unsafe { AllowSetForegroundWindow(ASFW_ANY) != 0 };
    log::debug!("windows-focus:allow-set-foreground source={source} ok={ok}");
    ok
}

pub fn force_foreground_window(hwnd: HWND, source: &str) -> bool {
    if hwnd.is_null() {
        log::warn!("windows-focus:foreground-failed source={source} reason=null-hwnd");
        return false;
    }

    allow_set_foreground_window_any(source);

    let foreground_before = unsafe { GetForegroundWindow() };
    let current_thread = unsafe { GetCurrentThreadId() };
    let target_thread = unsafe { GetWindowThreadProcessId(hwnd, std::ptr::null_mut()) };
    let foreground_thread = if foreground_before.is_null() {
        0
    } else {
        unsafe { GetWindowThreadProcessId(foreground_before, std::ptr::null_mut()) }
    };

    let attached_foreground = attach_thread_input(current_thread, foreground_thread);
    let attached_target = attach_thread_input(current_thread, target_thread);

    let show_cmd = if unsafe { IsIconic(hwnd) != 0 } {
        SW_RESTORE
    } else {
        SW_SHOW
    };

    let show_ok = unsafe { ShowWindowAsync(hwnd, show_cmd) != 0 };
    let bring_ok = unsafe { BringWindowToTop(hwnd) != 0 };
    let set_foreground_ok = unsafe { SetForegroundWindow(hwnd) != 0 };
    let mut pulse_ok = true;

    if unsafe { GetForegroundWindow() } != hwnd {
        unsafe {
            SwitchToThisWindow(hwnd, 1);
        }
        if unsafe { GetForegroundWindow() } != hwnd {
            pulse_ok = pulse_topmost(hwnd);
            let _ = unsafe { SetForegroundWindow(hwnd) };
        }
    }

    detach_thread_input(current_thread, target_thread, attached_target);
    detach_thread_input(current_thread, foreground_thread, attached_foreground);

    let foreground_after = unsafe { GetForegroundWindow() };
    let activated = foreground_after == hwnd;
    log::info!(
        "windows-focus:foreground source={source} activated={activated} show_ok={show_ok} bring_ok={bring_ok} set_foreground_ok={set_foreground_ok} pulse_ok={pulse_ok} target_thread={target_thread} foreground_thread={foreground_thread}"
    );
    activated
}

pub fn focus_file_manager_window_for_dir(dir: &Path, source: &str) -> bool {
    let target_key = normalized_path_key(dir);
    for attempt in 0..EXPLORER_FOCUS_ATTEMPTS {
        if let Some(hwnd_raw) = find_file_manager_window_for_dir(&target_key, source) {
            let hwnd = hwnd_raw as HWND;
            let activated = force_foreground_window(hwnd, source);
            log::info!(
                "windows-focus:explorer-focus source={source} activated={activated} attempt={} dir={dir:?}",
                attempt + 1
            );
            return activated;
        }

        std::thread::sleep(EXPLORER_FOCUS_RETRY_DELAY);
    }

    if let Some(hwnd) = first_visible_file_manager_window() {
        let activated = force_foreground_window(hwnd, source);
        log::warn!(
            "windows-focus:explorer-focus-fallback source={source} activated={activated} dir={dir:?}"
        );
        return activated;
    }

    log::warn!("windows-focus:explorer-focus-failed source={source} dir={dir:?}");
    false
}

fn attach_thread_input(current_thread: u32, other_thread: u32) -> bool {
    if current_thread == 0 || other_thread == 0 || current_thread == other_thread {
        return false;
    }
    unsafe { AttachThreadInput(current_thread, other_thread, 1) != 0 }
}

fn detach_thread_input(current_thread: u32, other_thread: u32, attached: bool) {
    if attached {
        unsafe {
            AttachThreadInput(current_thread, other_thread, 0);
        }
    }
}

fn pulse_topmost(hwnd: HWND) -> bool {
    let flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW;
    let topmost_ok = unsafe { SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags) != 0 };
    let notopmost_ok = unsafe { SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags) != 0 };
    topmost_ok && notopmost_ok
}

fn find_file_manager_window_for_dir(target_key: &str, source: &str) -> Option<isize> {
    let target_key = target_key.to_string();
    let source_label = source.to_string();
    let thread_source = source_label.clone();
    std::thread::spawn(move || find_file_manager_window_for_dir_on_sta(&target_key, &thread_source))
        .join()
        .unwrap_or_else(|_| {
            log::warn!("windows-focus:explorer-shellwindows-thread-panicked source={source_label}");
            None
        })
}

fn find_file_manager_window_for_dir_on_sta(target_key: &str, source: &str) -> Option<isize> {
    use windows::{
        core::{Interface, VARIANT},
        Win32::{
            Foundation::{S_FALSE, S_OK},
            System::Com::{
                CoAllowSetForegroundWindow, CoCreateInstance, CoInitializeEx, CLSCTX_ALL,
                COINIT_APARTMENTTHREADED,
            },
            UI::Shell::{IShellWindows, IWebBrowser2, ShellWindows},
        },
    };

    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    if hr.is_err() {
        log::warn!("windows-focus:explorer-com-init-failed source={source} hresult={hr:?}");
        return None;
    }
    let _com = ComApartment {
        uninitialize: matches!(hr, S_OK | S_FALSE),
    };

    let shell_windows: IShellWindows = match unsafe {
        CoCreateInstance(&ShellWindows, None::<&windows::core::IUnknown>, CLSCTX_ALL)
    } {
        Ok(shell_windows) => shell_windows,
        Err(error) => {
            log::warn!(
                "windows-focus:explorer-shellwindows-create-failed source={source} error={error}"
            );
            return None;
        }
    };

    if let Ok(shell_unknown) = shell_windows.cast::<windows::core::IUnknown>() {
        let _ = unsafe { CoAllowSetForegroundWindow(&shell_unknown, None) };
    }

    let count = match unsafe { shell_windows.Count() } {
        Ok(count) => count,
        Err(error) => {
            log::warn!(
                "windows-focus:explorer-shellwindows-count-failed source={source} error={error}"
            );
            return None;
        }
    };

    for index in 0..count {
        let item_index = VARIANT::from(index);
        let dispatch = match unsafe { shell_windows.Item(&item_index) } {
            Ok(dispatch) => dispatch,
            Err(error) => {
                log::debug!(
                    "windows-focus:explorer-shellwindows-item-failed source={source} index={index} error={error}"
                );
                continue;
            }
        };

        let browser = match dispatch.cast::<IWebBrowser2>() {
            Ok(browser) => browser,
            Err(error) => {
                log::debug!(
                    "windows-focus:explorer-shellwindows-cast-failed source={source} index={index} error={error}"
                );
                continue;
            }
        };

        let location_url = match unsafe { browser.LocationURL() }
            .ok()
            .and_then(|value| String::try_from(value).ok())
        {
            Some(location_url) => location_url,
            None => continue,
        };

        let Some(location_path) = shell_location_url_to_path(&location_url) else {
            continue;
        };

        if normalized_path_key(&location_path) != target_key {
            continue;
        }

        if let Ok(browser_unknown) = browser.cast::<windows::core::IUnknown>() {
            let _ = unsafe { CoAllowSetForegroundWindow(&browser_unknown, None) };
        }

        match unsafe { browser.HWND() } {
            Ok(hwnd) if hwnd.0 != 0 => return Some(hwnd.0),
            Ok(_) => log::warn!(
                "windows-focus:explorer-shellwindows-null-hwnd source={source} url={location_url:?}"
            ),
            Err(error) => log::warn!(
                "windows-focus:explorer-shellwindows-hwnd-failed source={source} url={location_url:?} error={error}"
            ),
        }
    }

    None
}

struct ComApartment {
    uninitialize: bool,
}

impl Drop for ComApartment {
    fn drop(&mut self) {
        if self.uninitialize {
            unsafe {
                windows::Win32::System::Com::CoUninitialize();
            }
        }
    }
}

fn shell_location_url_to_path(location_url: &str) -> Option<PathBuf> {
    let parsed = url::Url::parse(location_url).ok()?;
    (parsed.scheme() == "file")
        .then(|| parsed.to_file_path().ok())
        .flatten()
}

fn normalized_path_key(path: &Path) -> String {
    let canonical = dunce::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let value = canonical.to_string_lossy().replace('/', "\\");
    let value = value
        .strip_prefix(r"\\?\UNC\")
        .map(|path| format!(r"\\{path}"))
        .or_else(|| value.strip_prefix(r"\\?\").map(str::to_string))
        .unwrap_or(value);
    let value = if value.len() > 3 {
        value.trim_end_matches('\\').to_string()
    } else {
        value
    };
    value.to_lowercase()
}

fn first_visible_file_manager_window() -> Option<HWND> {
    let mut found: Option<HWND> = None;
    unsafe {
        EnumWindows(
            Some(enum_first_visible_file_manager_window),
            (&mut found as *mut Option<HWND>) as LPARAM,
        );
    }
    found
}

unsafe extern "system" fn enum_first_visible_file_manager_window(
    hwnd: HWND,
    lparam: LPARAM,
) -> BOOL {
    if unsafe { IsWindowVisible(hwnd) } == 0 {
        return 1;
    }

    let class_name = window_class_name(hwnd);
    if class_name != "CabinetWClass" && class_name != "ExploreWClass" {
        return 1;
    }

    let found = unsafe { &mut *(lparam as *mut Option<HWND>) };
    *found = Some(hwnd);
    0
}

fn window_class_name(hwnd: HWND) -> String {
    let mut buffer = [0u16; 256];
    let len = unsafe { GetClassNameW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32) };
    String::from_utf16_lossy(&buffer[..len.max(0) as usize])
}
