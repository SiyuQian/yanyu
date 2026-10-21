//! Interactive translation popover; creation happens only after source selection capture.
use crate::{managers::translation::TranslationManager, selection::SelectionBounds};
use tauri::{AppHandle, LogicalPosition, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};

/// Show near the selected text when AX exposes geometry, otherwise center on the primary monitor.
pub fn show(app: &AppHandle, bounds: Option<SelectionBounds>) -> tauri::Result<()> {
    let handle = app.clone();
    app.run_on_main_thread(move || {
        if let Err(error) = show_on_main(&handle, bounds) {
            log::error!("Could not show translation window: {error}");
            handle.state::<TranslationManager>().dismiss(&handle);
        }
    })
}
fn show_on_main(app: &AppHandle, bounds: Option<SelectionBounds>) -> tauri::Result<()> {
    let window = if let Some(window) = app.get_webview_window("translation_overlay") {
        window
    } else {
        let window = WebviewWindowBuilder::new(
            app,
            "translation_overlay",
            WebviewUrl::App("src/translation/index.html".into()),
        )
        .title("Yanyu")
        .inner_size(420., 280.)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(false)
        .build()?;
        let handle = app.clone();
        window.on_window_event(move |event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                handle.state::<TranslationManager>().dismiss(&handle);
            }
        });
        window
    };
    let monitors = app.available_monitors()?;
    let selected_monitor = bounds.and_then(|bounds| {
        monitors.iter().find(|monitor| {
            let position = monitor.position().to_logical::<f64>(monitor.scale_factor());
            let size = monitor.size().to_logical::<f64>(monitor.scale_factor());
            bounds.x >= position.x
                && bounds.x < position.x + size.width
                && bounds.y >= position.y
                && bounds.y < position.y + size.height
        })
    });
    if let Some(monitor) = selected_monitor.or(monitors.first()) {
        let position = monitor.position().to_logical::<f64>(monitor.scale_factor());
        let size = monitor.size().to_logical::<f64>(monitor.scale_factor());
        let (x, y) = if let Some(bounds) = bounds {
            (
                bounds.x + bounds.width.min(30.),
                bounds.y + bounds.height + 8.,
            )
        } else {
            (
                position.x + (size.width - 420.) / 2.,
                position.y + (size.height - 280.) / 2.,
            )
        };
        window.set_position(LogicalPosition::new(
            x.clamp(
                position.x + 8.,
                (position.x + size.width - 428.).max(position.x + 8.),
            ),
            y.clamp(
                position.y + 32.,
                (position.y + size.height - 288.).max(position.y + 32.),
            ),
        ))?;
    } else {
        window.center()?;
    }
    window.show()?;
    window.set_focus()?;
    Ok(())
}
