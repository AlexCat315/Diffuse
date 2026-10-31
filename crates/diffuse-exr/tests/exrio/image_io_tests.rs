//! `EXRIOTests` — Swift's `ImageIOTests.swift`.
//!
//! These use the public API only, so they live in the `exrio` integration test
//! binary (MIGRATION.md §5.6: no `@testable` import in the Swift suite).

use std::path::PathBuf;

use diffuse_exr::{EXRReader, EXRReaderError, EXRWriter, EXRWriterError, Layer, PixelType};

/// A unique temporary directory, standing in for
/// `FileManager.temporaryDirectory/UUID().uuidString`.
fn temporary_directory() -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let unique = format!("{nanos:X}-{:X}", COUNTER.fetch_add(1, Ordering::Relaxed));
    std::env::temp_dir().join(unique)
}

/// `"EXRWriter layer construction yields correct channel counts"`
#[test]
fn exr_writer_layer_construction() {
    let beauty = Layer::with_half("beauty", vec!["R", "G", "B", "A"]);
    let depth = Layer::new("depth", vec!["Z"], PixelType::Float);
    let path = temporary_directory().join("cove-layer.exr");
    let mut writer = EXRWriter::new(path.to_string_lossy(), 1920, 1080).expect("writer created");
    writer.add_layer(&beauty);
    writer.add_layer(&depth);

    assert_eq!(beauty.channels.len(), 4);
    assert_eq!(beauty.pixel_type, PixelType::Half);
    assert_eq!(depth.channels.len(), 1);
    assert_eq!(depth.pixel_type, PixelType::Float);
}

/// `"EXRReader init fails gracefully for nonexistent path"`
#[test]
fn exr_reader_nonexistent_path() {
    let path = temporary_directory().join("nonexistent-cove.exr");
    let error = match EXRReader::new(path.to_string_lossy()) {
        Ok(_) => panic!("open must fail for a nonexistent path"),
        Err(error) => error,
    };
    assert!(matches!(error, EXRReaderError::OpenFailed(_)));
}

/// `"EXRReader layerInfo returns nil for out-of-bounds index"`
#[test]
fn exr_reader_layer_info_out_of_bounds() {
    // The Swift test notes the reader cannot open anything without a real file
    // and only asserts the error type and that it names the path.
    let path = temporary_directory().join("nonexistent-cove.exr");
    match EXRReader::new(path.to_string_lossy()) {
        Ok(_) => panic!("Should have thrown"),
        Err(error) => assert!(
            matches!(error, EXRReaderError::OpenFailed(_)),
            "unexpected error: {error}"
        ),
    }

    // The named behaviour is checked against a real one-layer file, since the
    // Rust build always has the bridge available.
    let tmp_dir = temporary_directory();
    std::fs::create_dir_all(&tmp_dir).expect("temporary directory created");
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(tmp_dir.clone());

    let written = tmp_dir.join("single.exr");
    let mut writer = EXRWriter::new(written.to_string_lossy(), 4, 4).expect("writer created");
    writer.add_layer(&Layer::with_half("beauty", vec!["R", "G", "B", "A"]));
    assert!(writer.set_pixels(&vec![0.25_f32; 4 * 4 * 4], "beauty"));
    writer.write().expect("write succeeds");
    drop(writer);

    let reader = EXRReader::new(written.to_string_lossy()).expect("reader opens");
    assert_eq!(reader.layer_count(), 1);
    assert!(reader.layer_info(0).is_some());
    assert!(reader.layer_info(1).is_none());
    assert!(reader.layer_info(usize::MAX).is_none());
}

/// `"EXRWriter error types are distinct"`
#[test]
fn exr_writer_error_types() {
    let context = EXRWriterError::ContextCreationFailed;
    let layer = EXRWriterError::LayerCreationFailed("test".to_string());
    assert_ne!(format!("{context}"), format!("{layer}"));
}

/// `"EXR write-then-read roundtrip preserves RGBA pixel data"`
#[test]
fn exr_roundtrip_rgba() {
    let tmp_dir = temporary_directory();
    std::fs::create_dir_all(&tmp_dir).expect("temporary directory created");
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(tmp_dir.clone());

    let path = tmp_dir.join("roundtrip_rgba.exr");
    let width = 64usize;
    let height = 32usize;
    let pixel_count = width * height * 4;

    // Known pixel data.
    let mut original = vec![0.0_f32; pixel_count];
    for index in 0..(width * height) {
        let r = (index % 256) as f32 / 255.0;
        let g = ((index / 3) % 256) as f32 / 255.0;
        let b = ((index / 7) % 256) as f32 / 255.0;
        original[index * 4] = r;
        original[index * 4 + 1] = g;
        original[index * 4 + 2] = b;
        original[index * 4 + 3] = 1.0;
    }

    let mut writer = EXRWriter::new(path.to_string_lossy(), width, height).expect("writer created");
    writer.add_layer(&Layer::new(
        "beauty",
        vec!["R", "G", "B", "A"],
        PixelType::Float,
    ));
    assert!(writer.set_pixels(&original, "beauty"));
    writer.write().expect("write succeeds");
    drop(writer);

    let reader = EXRReader::new(path.to_string_lossy()).expect("reader opens");
    assert_eq!(reader.width(), width);
    assert_eq!(reader.height(), height);
    assert_eq!(reader.layer_count(), 1);

    let info = reader.layer_info(0).expect("layer 0 exists");
    assert_eq!(info.name, "beauty");

    let read_pixels = reader.read_pixels("beauty");
    assert_eq!(read_pixels.len(), pixel_count);

    for index in 0..pixel_count {
        assert!(
            (read_pixels[index] - original[index]).abs() < 0.005,
            "pixel {index} differs: {} vs {}",
            read_pixels[index],
            original[index]
        );
    }
}

/// `"EXR two-layer write produces correct layer count on read"`
#[test]
fn exr_two_layer_roundtrip() {
    let tmp_dir = temporary_directory();
    std::fs::create_dir_all(&tmp_dir).expect("temporary directory created");
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(tmp_dir.clone());

    let path = tmp_dir.join("twolayer.exr");
    let mut writer = EXRWriter::new(path.to_string_lossy(), 16, 16).expect("writer created");
    writer.add_layer(&Layer::with_half("beauty", vec!["R", "G", "B", "A"]));
    writer.add_layer(&Layer::with_half("depth", vec!["Z"]));

    let rgba = vec![0.5_f32; 16 * 16 * 4];
    let depth = vec![0.75_f32; 16 * 16];
    assert!(writer.set_pixels(&rgba, "beauty"));
    assert!(writer.set_pixels(&depth, "depth"));
    writer.write().expect("write succeeds");
    drop(writer);

    let reader = EXRReader::new(path.to_string_lossy()).expect("reader opens");
    assert_eq!(reader.layer_count(), 2);

    let names: Vec<String> = (0..reader.layer_count())
        .filter_map(|index| reader.layer_info(index).map(|info| info.name))
        .collect();
    assert!(names.contains(&"beauty".to_string()));
    assert!(names.contains(&"depth".to_string()));

    let read_depth = reader.read_pixels("depth");
    assert!(read_depth.len() >= 16 * 16);
    assert!((read_depth[0] - 0.75).abs() < 0.01);
}
