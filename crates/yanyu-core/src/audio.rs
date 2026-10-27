use std::path::Path;

use hound::{SampleFormat, WavReader};
use rubato::{FftFixedIn, Resampler};

use crate::CoreError;

pub fn decode_wav_to_16khz_mono(path: impl AsRef<Path>) -> Result<Vec<f32>, CoreError> {
    let path = path.as_ref();
    let mut reader = WavReader::open(path).map_err(|error| CoreError::AudioRead {
        message: format!("{}: {error}", path.display()),
    })?;
    let spec = reader.spec();
    if !(1..=8).contains(&spec.channels) {
        return Err(CoreError::UnsupportedAudio {
            message: format!("expected 1–8 channels, found {}", spec.channels),
        });
    }
    if !(8_000..=192_000).contains(&spec.sample_rate) {
        return Err(CoreError::UnsupportedAudio {
            message: format!("unsupported sample rate: {} Hz", spec.sample_rate),
        });
    }

    let interleaved = match (spec.sample_format, spec.bits_per_sample) {
        (SampleFormat::Int, 16) => reader
            .samples::<i16>()
            .map(|sample| {
                sample
                    .map(|value| value as f32 / 32_768.0)
                    .map_err(|error| CoreError::AudioRead {
                        message: format!("{}: {error}", path.display()),
                    })
            })
            .collect::<Result<Vec<_>, _>>()?,
        (SampleFormat::Float, 32) => reader
            .samples::<f32>()
            .map(|sample| {
                sample.map_err(|error| CoreError::AudioRead {
                    message: format!("{}: {error}", path.display()),
                })
            })
            .collect::<Result<Vec<_>, _>>()?,
        (format, bits) => {
            return Err(CoreError::UnsupportedAudio {
                message: format!("{bits}-bit {format:?} WAV samples are not supported"),
            });
        }
    };

    if interleaved.is_empty() {
        return Err(CoreError::UnsupportedAudio {
            message: "recording contains no audio samples".to_owned(),
        });
    }
    if interleaved.len() % usize::from(spec.channels) != 0 {
        return Err(CoreError::AudioRead {
            message: "sample count does not contain complete audio frames".to_owned(),
        });
    }

    let channel_count = usize::from(spec.channels);
    let mut mono = Vec::with_capacity(interleaved.len() / channel_count);
    for frame in interleaved.chunks_exact(channel_count) {
        let mut sum = 0.0;
        for sample in frame {
            if !sample.is_finite() {
                return Err(CoreError::UnsupportedAudio {
                    message: "recording contains a non-finite audio sample".to_owned(),
                });
            }
            sum += sample.clamp(-1.0, 1.0);
        }
        mono.push((sum / channel_count as f32).clamp(-1.0, 1.0));
    }

    if spec.sample_rate == 16_000 {
        return Ok(mono);
    }

    resample_to_16khz(&mono, spec.sample_rate)
}

fn resample_to_16khz(input: &[f32], input_rate: u32) -> Result<Vec<f32>, CoreError> {
    const CHUNK_SIZE: usize = 1_024;
    let mut resampler = FftFixedIn::<f32>::new(input_rate as usize, 16_000, CHUNK_SIZE, 1, 1)
        .map_err(|error| CoreError::Resample {
            message: error.to_string(),
        })?;

    let mut output = Vec::with_capacity(input.len() * 16_000 / input_rate as usize + 512);
    let mut chunks = input.chunks_exact(CHUNK_SIZE);
    for chunk in &mut chunks {
        let resampled = resampler
            .process(&[chunk], None)
            .map_err(|error| CoreError::Resample {
                message: error.to_string(),
            })?;
        output.extend_from_slice(&resampled[0]);
    }

    let remainder = chunks.remainder();
    if !remainder.is_empty() {
        let resampled = resampler
            .process_partial(Some(&[remainder]), None)
            .map_err(|error| CoreError::Resample {
                message: error.to_string(),
            })?;
        output.extend_from_slice(&resampled[0]);
    }

    let target_samples = input.len() * 16_000 / input_rate as usize;
    let delay = resampler.output_delay();
    let required_samples = target_samples.saturating_add(delay);
    for _ in 0..8 {
        if output.len() >= required_samples {
            break;
        }
        let flushed = resampler
            .process_partial::<&[f32]>(None, None)
            .map_err(|error| CoreError::Resample {
                message: error.to_string(),
            })?;
        if flushed[0].is_empty() {
            break;
        }
        output.extend_from_slice(&flushed[0]);
    }

    let end = delay.saturating_add(target_samples);
    if output.len() < end {
        return Err(CoreError::Resample {
            message: format!(
                "resampler produced {} samples, expected at least {end}",
                output.len()
            ),
        });
    }
    Ok(output[delay..end].to_vec())
}

#[cfg(test)]
mod tests {
    use std::f32::consts::TAU;

    use hound::{SampleFormat, WavSpec, WavWriter};
    use tempfile::tempdir;

    use super::*;

    fn write_pcm16(path: &Path, sample_rate: u32, channels: u16, samples: &[i16]) {
        let spec = WavSpec {
            channels,
            sample_rate,
            bits_per_sample: 16,
            sample_format: SampleFormat::Int,
        };
        let mut writer = WavWriter::create(path, spec).expect("create WAV fixture");
        for sample in samples {
            writer.write_sample(*sample).expect("write WAV fixture");
        }
        writer.finalize().expect("finish WAV fixture");
    }

    fn write_float32(path: &Path, samples: &[f32]) {
        let spec = WavSpec {
            channels: 1,
            sample_rate: 16_000,
            bits_per_sample: 32,
            sample_format: SampleFormat::Float,
        };
        let mut writer = WavWriter::create(path, spec).expect("create float WAV fixture");
        for sample in samples {
            writer
                .write_sample(*sample)
                .expect("write float WAV fixture");
        }
        writer.finalize().expect("finish float WAV fixture");
    }

    fn sine_wave(sample_rate: u32, seconds: f32) -> Vec<i16> {
        let count = (sample_rate as f32 * seconds) as usize;
        (0..count)
            .map(|index| {
                let phase = TAU * 440.0 * index as f32 / sample_rate as f32;
                (phase.sin() * i16::MAX as f32 * 0.5) as i16
            })
            .collect()
    }

    #[test]
    fn resamples_48khz_recording_to_16khz_with_expected_duration() {
        let directory = tempdir().expect("create temporary directory");
        let path = directory.path().join("speech.wav");
        write_pcm16(&path, 48_000, 1, &sine_wave(48_000, 1.0));

        let audio = decode_wav_to_16khz_mono(&path).expect("decode WAV");

        assert_eq!(audio.len(), 16_000);
        assert!(audio
            .iter()
            .all(|sample| sample.is_finite() && sample.abs() <= 1.0));
        let rms =
            (audio.iter().map(|sample| sample * sample).sum::<f32>() / audio.len() as f32).sqrt();
        assert!((0.30..0.42).contains(&rms), "unexpected 440 Hz RMS: {rms}");
    }

    #[test]
    fn downmixes_stereo_before_resampling() {
        let directory = tempdir().expect("create temporary directory");
        let path = directory.path().join("stereo.wav");
        let mut stereo = Vec::with_capacity(48_000 * 2);
        for sample in sine_wave(48_000, 0.5) {
            stereo.push(sample);
            stereo.push(sample);
        }
        write_pcm16(&path, 48_000, 2, &stereo);

        let audio = decode_wav_to_16khz_mono(&path).expect("decode WAV");

        assert_eq!(audio.len(), 8_000);
        assert!(audio.iter().any(|sample| sample.abs() > 0.1));
    }

    #[test]
    fn reads_av_audio_float_wav_and_keeps_16khz_samples() {
        let directory = tempdir().expect("create temporary directory");
        let path = directory.path().join("float.wav");
        let samples = vec![-0.5, 0.0, 0.25, 1.0];
        write_float32(&path, &samples);

        let audio = decode_wav_to_16khz_mono(&path).expect("decode float WAV");

        assert_eq!(audio, samples);
    }

    #[test]
    fn resamples_short_44khz_recording_without_losing_samples() {
        let directory = tempdir().expect("create temporary directory");
        let path = directory.path().join("short-44khz.wav");
        write_pcm16(&path, 44_100, 1, &sine_wave(44_100, 0.05));

        let audio = decode_wav_to_16khz_mono(&path).expect("decode WAV");

        assert_eq!(audio.len(), 800);
    }

    #[test]
    fn rejects_a_missing_file_with_a_typed_error() {
        let error = decode_wav_to_16khz_mono("/tmp/yanyu-missing-audio.wav")
            .expect_err("missing input must fail");

        assert!(matches!(error, CoreError::AudioRead { .. }));
    }
}
