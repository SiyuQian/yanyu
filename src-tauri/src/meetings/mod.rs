mod manager;
pub use manager::MeetingManager;
mod capture;
mod diarization;
mod notes;
mod store;
pub use store::*;
#[cfg(test)]
mod tests;

pub use capture::available;
fn window_end(start: u32, duration: u32, tail: &[f32]) -> u32 {
    let maximum = (start + 45000).min(duration);
    if maximum == duration || tail.len() < 16000 {
        return maximum;
    }
    let index = tail
        .chunks_exact(800)
        .enumerate()
        .min_by(|(a, x), (b, y)| {
            let left: f32 = x.iter().map(|s| s * s).sum();
            let right: f32 = y.iter().map(|s| s * s).sum();
            left.total_cmp(&right).then_with(|| b.cmp(a))
        })
        .map(|(index, _)| index)
        .unwrap_or(19);
    maximum - 1000 + (index as u32 + 1) * 50
}

#[cfg(test)]
mod experiments;
