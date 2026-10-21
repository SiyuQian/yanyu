//! Small CoreFoundation ownership wrapper around the read-only AX selection API.
use super::{validate_text, Selection, SelectionBounds, SelectionError};
use std::{
    ffi::{c_char, c_void, CStr},
    ptr,
};
type Ref = *const c_void;
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateSystemWide() -> Ref;
    fn AXUIElementSetMessagingTimeout(element: Ref, seconds: f32) -> i32;
    fn AXUIElementCopyAttributeValue(element: Ref, attribute: Ref, value: *mut Ref) -> i32;
    fn AXUIElementCopyParameterizedAttributeValue(
        element: Ref,
        attribute: Ref,
        parameter: Ref,
        value: *mut Ref,
    ) -> i32;
    fn AXValueGetTypeID() -> usize;
    fn AXValueGetValue(value: Ref, kind: i32, output: *mut c_void) -> bool;
}
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(value: Ref);
    fn CFGetTypeID(value: Ref) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringCreateWithCString(allocator: Ref, value: *const c_char, encoding: u32) -> Ref;
    fn CFStringGetLength(value: Ref) -> isize;
    fn CFStringGetCString(value: Ref, buffer: *mut c_char, size: isize, encoding: u32) -> bool;
}
const UTF8: u32 = 0x08000100;
struct Owned(Ref);
impl Drop for Owned {
    fn drop(&mut self) {
        // Every Owned value comes from a successful Create or Copy call.
        unsafe { CFRelease(self.0) }
    }
}
fn attribute_name(name: &CStr) -> Result<Owned, SelectionError> {
    let value = unsafe { CFStringCreateWithCString(ptr::null(), name.as_ptr(), UTF8) };
    if value.is_null() {
        Err(SelectionError::Unsupported)
    } else {
        Ok(Owned(value))
    }
}
fn error(code: i32) -> SelectionError {
    match code {
        -25211 => SelectionError::PermissionDenied,
        -25212 => SelectionError::NoSelection,
        _ => SelectionError::Unsupported,
    }
}
fn attribute(element: Ref, name: &CStr) -> Result<Owned, SelectionError> {
    let name = attribute_name(name)?;
    let mut value = ptr::null();
    let result = unsafe { AXUIElementCopyAttributeValue(element, name.0, &mut value) };
    if result != 0 {
        return Err(error(result));
    }
    if value.is_null() {
        return Err(SelectionError::NoSelection);
    }
    Ok(Owned(value))
}
#[repr(C)]
#[derive(Default)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
fn bounds(element: Ref) -> Option<SelectionBounds> {
    let range = attribute(element, c"AXSelectedTextRange").ok()?;
    let name = attribute_name(c"AXBoundsForRange").ok()?;
    let mut value = ptr::null();
    let result =
        unsafe { AXUIElementCopyParameterizedAttributeValue(element, name.0, range.0, &mut value) };
    if result != 0 || value.is_null() {
        return None;
    }
    let value = Owned(value);
    let mut rect = Rect::default();
    if unsafe {
        CFGetTypeID(value.0) != AXValueGetTypeID()
            || !AXValueGetValue(value.0, 3, (&mut rect as *mut Rect).cast())
    } {
        return None;
    }
    if ![rect.x, rect.y, rect.width, rect.height]
        .iter()
        .all(|v| v.is_finite())
        || rect.width < 0.
        || rect.height <= 0.
    {
        return None;
    }
    Some(SelectionBounds {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    })
}
pub(super) fn capture() -> Result<Selection, SelectionError> {
    if !unsafe { AXIsProcessTrusted() } {
        return Err(SelectionError::PermissionDenied);
    }
    let system = unsafe { AXUIElementCreateSystemWide() };
    if system.is_null() {
        return Err(SelectionError::Unsupported);
    }
    let system = Owned(system);
    // Bound unresponsive target applications; no synthetic copy shortcut is ever sent.
    unsafe {
        AXUIElementSetMessagingTimeout(system.0, 1.0);
    }
    let application = attribute(system.0, c"AXFocusedApplication")?;
    let focused = attribute(application.0, c"AXFocusedUIElement")?;
    let selected = attribute(focused.0, c"AXSelectedText")?;
    if unsafe { CFGetTypeID(selected.0) != CFStringGetTypeID() } {
        return Err(SelectionError::Unsupported);
    }
    let length = unsafe { CFStringGetLength(selected.0) };
    if length > 4000 {
        return Err(SelectionError::TooLong);
    }
    if length < 0 {
        return Err(SelectionError::Unsupported);
    }
    let mut buffer = vec![0u8; length as usize * 4 + 1];
    if !unsafe {
        CFStringGetCString(
            selected.0,
            buffer.as_mut_ptr().cast(),
            buffer.len() as isize,
            UTF8,
        )
    } {
        return Err(SelectionError::Unsupported);
    }
    let text = CStr::from_bytes_until_nul(&buffer)
        .map_err(|_| SelectionError::Unsupported)?
        .to_str()
        .map_err(|_| SelectionError::Unsupported)?
        .to_string();
    Ok(Selection {
        text: validate_text(text)?,
        bounds: bounds(focused.0),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accessibility_failures_have_actionable_error_codes() {
        assert_eq!(error(-25211).code(), "permission_denied");
        assert_eq!(error(-25212).code(), "no_selection");
        assert_eq!(error(-25205).code(), "unsupported_selection");
        assert_eq!(error(-25204).code(), "unsupported_selection");
    }
}
