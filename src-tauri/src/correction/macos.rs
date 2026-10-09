//! Fail-closed accessibility adapter. All AX operations run on the main thread.
use super::guards::inserted_value;
use std::ffi::c_void;
use std::ptr;

type Ref = *const c_void;
#[repr(C)]
#[derive(Clone, Copy, PartialEq)]
struct Range {
    location: isize,
    length: isize,
}
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXUIElementCreateSystemWide() -> Ref;
    fn AXUIElementCreateApplication(pid: i32) -> Ref;
    fn AXUIElementGetPid(element: Ref, pid: *mut i32) -> i32;
    fn AXUIElementCopyAttributeValue(element: Ref, attribute: Ref, value: *mut Ref) -> i32;
    fn AXUIElementSetAttributeValue(element: Ref, attribute: Ref, value: Ref) -> i32;
    fn AXUIElementIsAttributeSettable(element: Ref, attribute: Ref, settable: *mut u8) -> i32;
    fn AXValueCreate(kind: u32, value: *const c_void) -> Ref;
    fn AXValueGetValue(value: Ref, kind: u32, output: *mut c_void) -> bool;
    fn AXValueGetType(value: Ref) -> u32;
    fn AXValueGetTypeID() -> usize;
}
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(value: Ref);
    fn CFEqual(a: Ref, b: Ref) -> u8;
    fn CFGetTypeID(value: Ref) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringCreateWithCharacters(allocator: Ref, text: *const u16, length: isize) -> Ref;
    fn CFStringGetLength(value: Ref) -> isize;
    fn CFStringGetCharacters(value: Ref, range: Range, buffer: *mut u16);
}
struct Owned(Ref);
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.0);
        }
    }
}
// CF objects are retained across IPC calls; AX access is restricted to the main thread.
unsafe impl Send for Owned {}
impl Owned {
    fn new(value: Ref) -> Option<Self> {
        (!value.is_null()).then(|| Self(value))
    }
}
fn string(text: &str) -> Option<Owned> {
    let units: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        Owned::new(CFStringCreateWithCharacters(
            ptr::null(),
            units.as_ptr(),
            units.len() as isize,
        ))
    }
}
fn attr(element: Ref, name: &str) -> Option<Owned> {
    let name = string(name)?;
    let mut value = ptr::null();
    unsafe {
        (AXUIElementCopyAttributeValue(element, name.0, &mut value) == 0)
            .then(|| Owned::new(value))
            .flatten()
    }
}
fn text_attr(element: Ref, name: &str) -> Option<String> {
    let value = attr(element, name)?;
    unsafe {
        if CFGetTypeID(value.0) != CFStringGetTypeID() {
            return None;
        }
        let length = CFStringGetLength(value.0);
        if !(0..=32768).contains(&length) {
            return None;
        }
        let mut units = vec![0; length as usize];
        CFStringGetCharacters(
            value.0,
            Range {
                location: 0,
                length,
            },
            units.as_mut_ptr(),
        );
        String::from_utf16(&units).ok()
    }
}
fn selected(element: Ref) -> Option<Range> {
    let value = attr(element, "AXSelectedTextRange")?;
    let mut range = Range {
        location: 0,
        length: 0,
    };
    unsafe {
        if CFGetTypeID(value.0) != AXValueGetTypeID() || AXValueGetType(value.0) != 4 {
            return None;
        }
        if !AXValueGetValue(value.0, 4, &mut range as *mut Range as *mut c_void) {
            return None;
        }
    }
    (range.location >= 0 && range.length >= 0).then_some(range)
}
fn settable(element: Ref, name: &str) -> bool {
    let Some(name) = string(name) else {
        return false;
    };
    let mut settable = 0;
    unsafe { AXUIElementIsAttributeSettable(element, name.0, &mut settable) == 0 && settable != 0 }
}
fn set(element: Ref, name: &str, value: Ref) -> bool {
    let Some(name) = string(name) else {
        return false;
    };
    unsafe { AXUIElementSetAttributeValue(element, name.0, value) == 0 }
}
fn focused() -> Option<Owned> {
    let system = unsafe { Owned::new(AXUIElementCreateSystemWide()) }?;
    attr(system.0, "AXFocusedUIElement")
}
fn same(a: Ref, b: Ref) -> bool {
    unsafe { CFEqual(a, b) != 0 }
}
fn supported(element: Ref) -> bool {
    matches!(
        text_attr(element, "AXRole").as_deref(),
        Some("AXTextField" | "AXTextArea")
    ) && text_attr(element, "AXSubrole").as_deref() != Some("AXSecureTextField")
        && settable(element, "AXSelectedText")
        && settable(element, "AXSelectedTextRange")
}

pub struct Target {
    element: Owned,
    pid: i32,
    before: String,
    expected: String,
    range: Range,
}
impl Target {
    pub fn capture(delivered: &str) -> Option<Self> {
        let element = focused()?;
        if !supported(element.0) {
            return None;
        }
        let before = text_attr(element.0, "AXValue")?;
        let selection = selected(element.0)?;
        let expected = inserted_value(
            &before,
            selection.location as usize,
            selection.length as usize,
            delivered,
        )?;
        if expected.encode_utf16().count() > 32768 {
            return None;
        }
        let mut pid = 0;
        if unsafe { AXUIElementGetPid(element.0, &mut pid) } != 0
            || pid == std::process::id() as i32
        {
            return None;
        }
        Some(Self {
            element,
            pid,
            before,
            expected,
            range: Range {
                location: selection.location,
                length: delivered.encode_utf16().count() as isize,
            },
        })
    }
    pub fn confirm(&self) -> bool {
        focused().is_some_and(|focus| same(focus.0, self.element.0))
            && self.before != self.expected
            && text_attr(self.element.0, "AXValue").as_deref() == Some(&self.expected)
    }
    pub fn matches_focus(&self) -> bool {
        focused().is_some_and(|focus| same(focus.0, self.element.0))
            && text_attr(self.element.0, "AXValue").as_deref() == Some(&self.expected)
    }
    /// Returns None before mutation, or a confirmed/uncertain result after mutation.
    pub fn replace(&self, text: &str) -> Option<bool> {
        if crate::secure_input::is_enabled_now() {
            return None;
        }
        let focus = focused()?;
        let mut focus_pid = 0;
        if unsafe { AXUIElementGetPid(focus.0, &mut focus_pid) } != 0
            || focus_pid != std::process::id() as i32
        {
            return None;
        }
        let app = unsafe { Owned::new(AXUIElementCreateApplication(self.pid)) }?;
        let saved_focus = attr(app.0, "AXFocusedUIElement")?;
        if !supported(self.element.0)
            || !super::guards::can_replace(
                same(saved_focus.0, self.element.0),
                &self.expected,
                &text_attr(self.element.0, "AXValue")?,
            )
        {
            return None;
        }
        let next = inserted_value(
            &self.expected,
            self.range.location as usize,
            self.range.length as usize,
            text,
        )?;
        if next.encode_utf16().count() > 32768 {
            return None;
        }
        let old_selection = selected(self.element.0)?;
        let range = unsafe {
            Owned::new(AXValueCreate(
                4,
                &self.range as *const Range as *const c_void,
            ))
        }?;
        let replacement = string(text)?;
        if !set(self.element.0, "AXSelectedTextRange", range.0) {
            return None;
        }
        if selected(self.element.0) != Some(self.range)
            || text_attr(self.element.0, "AXValue").as_deref() != Some(&self.expected)
        {
            return None;
        }
        let written = set(self.element.0, "AXSelectedText", replacement.0);
        let confirmed = written && text_attr(self.element.0, "AXValue").as_deref() == Some(&next);
        if !written {
            if let Some(old) = unsafe {
                Owned::new(AXValueCreate(
                    4,
                    &old_selection as *const Range as *const c_void,
                ))
            } {
                set(self.element.0, "AXSelectedTextRange", old.0);
            }
        }
        Some(confirmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_accessibility_values_do_not_acquire_ownership() {
        assert!(Owned::new(ptr::null()).is_none());
    }
}
