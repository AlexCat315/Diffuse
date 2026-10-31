//! Byte-exact `.dmesh` persistence (MIGRATION.md §5.4).
//!
//! The fixture `fixtures/geometry-document-pretty.json` was captured by compiling
//! the Swift declarations with Swift 6.4.1 and encoding with
//! `JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys])` — the formatter
//! `GeometryDocument.save(to:)` uses. §10 notes that the default `JSONEncoder` key
//! order is randomized per process, so `.sortedKeys` is the only byte-stable
//! target.

use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{
    GeometryDocument, GeometryMaterial, GeometrySource,
};
use diffuse_assets::geometry::geometry_modifier::{
    GeometryAxis, GeometryModifier, GeometryModifierEntry,
};
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_assets::swift_json::to_sorted_pretty;
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Int2};

fn fixture() -> &'static str {
    include_str!("fixtures/geometry-document-pretty.json")
}

/// The document the Swift capture encoded.
fn captured_document() -> GeometryDocument {
    GeometryDocument::new(
        "Fixture",
        GeometrySource::Grid {
            size: Float2::new(3.0, 3.0),
            segments: Int2::new(4, 4),
        },
        vec![
            GeometryModifierEntry::new(GeometryModifier::Subdivision { levels: 1 }, true, "a"),
            GeometryModifierEntry::new(
                GeometryModifier::Array {
                    count: 2,
                    offset: Float3::new(2.0, 0.0, 0.0),
                },
                false,
                "b",
            ),
            GeometryModifierEntry::new(GeometryModifier::Solidify { thickness: 0.2 }, true, "c"),
            GeometryModifierEntry::new(
                GeometryModifier::Mirror {
                    axis: GeometryAxis::Z,
                    offset: 1e-5,
                    weld_distance: 1e-7,
                },
                true,
                "d",
            ),
        ],
        GeometryShading::Smooth,
        vec![
            GeometryMaterial {
                name: "Copper".to_string(),
                base_color: Float4::new(0.65, 0.25, 0.1, 1.0),
                metallic: 0.8,
                roughness: 0.35,
            },
            GeometryMaterial {
                name: "Empty".to_string(),
                base_color: Float4::new(1.0, 1.0, 1.0, 1.0),
                metallic: 0.0,
                roughness: 0.5,
            },
        ],
    )
}

// The pretty writer reproduces Swift's `.dmesh` bytes exactly.
#[test]
fn pretty_output_matches_swift_bytes() {
    let encoded = to_sorted_pretty(&captured_document()).expect("encode");
    assert_eq!(encoded.as_str(), fixture());
}

// The empty-container layout is the part serde_json gets wrong.
#[test]
fn empty_containers_use_swifts_blank_line_layout() {
    let document =
        GeometryDocument::with_source("Minimal", GeometrySource::Box { size: Float3::ONE });
    let encoded = to_sorted_pretty(&document).expect("encode");
    let expected = concat!(
        "{\n",
        "  \"materials\" : [\n",
        "    {\n",
        "      \"baseColor\" : [\n",
        "        1,\n",
        "        1,\n",
        "        1,\n",
        "        1\n",
        "      ],\n",
        "      \"metallic\" : 0,\n",
        "      \"name\" : \"Material\",\n",
        "      \"roughness\" : 0.5\n",
        "    }\n",
        "  ],\n",
        "  \"modifiers\" : [\n",
        "\n",
        "  ],\n",
        "  \"name\" : \"Minimal\",\n",
        "  \"shading\" : \"flat\",\n",
        "  \"source\" : {\n",
        "    \"box\" : {\n",
        "      \"size\" : [\n",
        "        1,\n",
        "        1,\n",
        "        1\n",
        "      ]\n",
        "    }\n",
        "  },\n",
        "  \"version\" : 1\n",
        "}",
    );
    assert_eq!(encoded, expected);
}

// Decoding the fixture and re-encoding it reproduces the same bytes, which is the
// round-trip §5.4 requires.
#[test]
fn fixture_round_trips_byte_for_byte() {
    let decoded: GeometryDocument = serde_json::from_str(fixture()).expect("decode");
    assert_eq!(decoded, captured_document());
    let re_encoded = to_sorted_pretty(&decoded).expect("encode");
    assert_eq!(re_encoded.as_str(), fixture());
}

// `save` writes exactly the pretty bytes, and `load` reads them back.
#[test]
fn save_and_load_preserve_bytes() {
    let directory = std::env::temp_dir().join(format!(
        "dmesh-bytes-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("fixture.dmesh");
    let document = captured_document();
    // The modifier stack includes an invalid disabled entry, so evaluate would
    // reject it; `save` validates first, so use a clean stack that still covers
    // every persisted case.
    let mut savable = document.clone();
    savable.modifiers.retain(|entry| entry.id != "d");
    savable
        .save(&path.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let written = std::fs::read_to_string(&path).unwrap();
    let expected = to_sorted_pretty(&savable).unwrap();
    assert_eq!(written, expected);
    let loaded = GeometryDocument::load(&path.to_string_lossy()).unwrap();
    assert_eq!(loaded, savable);
    let _ = std::fs::remove_dir_all(&directory);
}

// Scalar text matches Swift's thresholds for both widths.
#[test]
fn scalar_notation_matches_swift() {
    let document = GeometryDocument::new(
        "Scalars",
        GeometrySource::Box {
            size: Float3::new(1.0e-5, 1.0e7, 1.0e8),
        },
        Vec::new(),
        GeometryShading::Flat,
        vec![GeometryMaterial {
            name: "S".to_string(),
            base_color: Float4::new(-0.0, 0.0001, 1.0, 0.0),
            metallic: 0.0,
            roughness: 1e-7,
        }],
    );
    let encoded = to_sorted_pretty(&document).unwrap();
    assert!(
        encoded.contains("\"size\" : [\n        1e-05,\n        10000000,\n        1e+08\n      ]")
    );
    assert!(encoded.contains(
        "\"baseColor\" : [\n        -0,\n        0.0001,\n        1,\n        0\n      ]"
    ));
    assert!(encoded.contains("\"roughness\" : 1e-07"));
}
