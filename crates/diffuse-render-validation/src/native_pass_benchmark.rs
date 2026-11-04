use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use cove_graphics::rhi::{
    Device, DeviceConfig, GraphicsApi, RhiError, RhiResult, Texture, platform_default_backends,
};
use cove_logging::{Level, LogEvent, LogSystem, LoggingConfiguration};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::import::gltf_importer::GLTFImporterError;
use diffuse_assets::swift_json::{SwiftJsonError, to_sorted_pretty};
use diffuse_render::native::{
    native_renderer::NativeRenderer, passes::native_grid_renderer::NativeGridRenderer,
};
use diffuse_render::{RenderDrawableSize, RenderFrameStats, RenderPacket, RenderSettings};
use serde::{Deserialize, Serialize};

use crate::probes::{
    animated_probe_scene::AnimatedProbeScene, grid_probe_scene::GridProbeScene,
    mesh_probe_scene::MeshProbeScene, particle_probe_scene::ParticleProbeScene,
    particle_simulation_probe_scene::ParticleSimulationProbeScene, pbr_probe_scene::PBRProbeScene,
    post_probe_scene::PostProbeScene, stylized_probe_scene::StylizedProbeScene,
};
use crate::reference::grid_image::{GridImage, GridImageDifference};

#[derive(Debug, thiserror::Error)]
pub enum NativeValidationError {
    #[error(transparent)]
    Rhi(#[from] RhiError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Import(#[from] GLTFImporterError),
    #[error(transparent)]
    Json(#[from] SwiftJsonError),
}

pub enum NativePassBenchmark {}
impl NativePassBenchmark {
    pub fn run(arguments: &[String]) -> Result<(), NativeValidationError> {
        let options = PassBenchmarkOptions::new(arguments)?;
        std::fs::create_dir_all(&options.output)?;
        let _fixture = if options.scene == ProbeScene::Animated {
            AssetRegistry::shared().register_for_testing(AnimatedProbeScene::skinned_fixture(), 2);
            Some(AnimatedFixture)
        } else {
            None
        };
        let packet = options.scene.packet(options.size, 0);
        let frame_packet = |frame: i64| match options.scene {
            ProbeScene::Simulation
            | ProbeScene::Particles
            | ProbeScene::Stylized
            | ProbeScene::Post
            | ProbeScene::Animated => options.scene.packet(options.size, frame),
            _ => {
                let mut packet = packet.clone();
                packet.frame_index = frame;
                if options.scene == ProbeScene::Pbr {
                    packet.scene.camera.eye.x += (frame % 11) as f32 * 0.002;
                }
                packet
            }
        };
        let mut results = Vec::new();
        let mut images = BTreeMap::new();
        for &api in &options.backends {
            let device = Device::make(DeviceConfig {
                preferred_backends: vec![api],
                enable_validation: false,
                frames_in_flight: 3,
                ..DeviceConfig::default()
            })?;
            let mut renderer = if options.scene == ProbeScene::Grid {
                BenchmarkRenderer::Grid(Box::new(NativeGridRenderer::new(&device, None)?))
            } else {
                BenchmarkRenderer::Scene(Box::new(NativeRenderer::new(
                    &device,
                    None,
                    AssetRegistry::shared(),
                    None,
                    &RenderSettings::default(),
                    &[64],
                )?))
            };
            let result = Self::measure(
                format!("native-{}", api_name(api)),
                device.device_name(),
                &options,
                |frame| renderer.render(&frame_packet(frame)),
                || device.wait_until_idle(),
            )?;
            let texture = renderer
                .color_texture()
                .ok_or_else(|| RhiError::invalid_argument("benchmark produced no color"))?;
            images.insert(
                result.backend.clone(),
                GridImage::readback(&device, texture, options.size)?,
            );
            LogSystem::logger("com.cove.tools").log(&LogEvent::new(
                Level::Info,
                format!(
                    "{}: CPU p50 {:.1} us, completed batch {:.3} ms/frame",
                    result.backend,
                    result.cpu_frame.p50_microseconds,
                    result.completed_batch.p50_microseconds / 1000.0
                ),
            ));
            results.push(result);
        }
        let baseline = results
            .first()
            .ok_or_else(|| RhiError::invalid_argument("benchmark needs a native backend"))?;
        let expected = images
            .get(&baseline.backend)
            .ok_or_else(|| RhiError::invalid_argument("benchmark needs a native backend"))?;
        for result in results.iter().skip(1) {
            if result.pass_frames != baseline.pass_frames
                || result.pass_draws != baseline.pass_draws
                || result.particle_work != baseline.particle_work
                || result.simulation_work != baseline.simulation_work
            {
                return Err(RhiError::invalid_argument("native backend workloads differ").into());
            }
        }
        let mut differences = BTreeMap::new();
        for (name, image) in &images {
            GridImage::write_ppm(
                image,
                options.size,
                &options.output.join(format!("{name}.ppm")),
            )?;
            if *name != baseline.backend {
                differences.insert(name.clone(), GridImage::difference(image, expected)?);
            }
        }
        let report = PassBenchmarkReport {
            scene: options.scene.name(),
            width: options.size.width,
            height: options.size.height,
            frames: options.frames,
            warmup: options.warmup,
            repeats: options.repeats,
            results: &results,
            image_differences: &differences,
            environment: PassBenchmarkEnvironment::new()?,
        };
        let report_path = options.output.join("report.json");
        std::fs::write(&report_path, to_sorted_pretty(&report)?)?;
        LogSystem::logger("com.cove.tools").log(&LogEvent::new(
            Level::Info,
            format!("report: {}", report_path.display()),
        ));
        for (name, difference) in differences {
            if !(difference.mean_absolute_channel_error < 0.5
                && difference.pixels_over_three < 1.max(difference.pixel_count / 100))
            {
                return Err(RhiError::invalid_argument(format!(
                    "{name} image differs from the first native backend: {difference:?}"
                ))
                .into());
            }
        }
        Ok(())
    }

    fn measure(
        name: String,
        device: String,
        options: &PassBenchmarkOptions,
        mut render: impl FnMut(i64) -> RhiResult<RenderFrameStats>,
        mut finish: impl FnMut() -> RhiResult<()>,
    ) -> RhiResult<PassBenchmarkResult> {
        for frame in 0..options.warmup {
            render(frame as i64)?;
            if (frame + 1) % 3 == 0 {
                finish()?;
            }
        }
        finish()?;
        let mut pass_frames = BTreeMap::new();
        let mut pass_draws = BTreeMap::new();
        let mut frame_samples = Vec::new();
        let mut encode_samples = Vec::new();
        let mut submit_samples = Vec::new();
        let mut batches = Vec::new();
        let mut particle_work = PassParticleWork::default();
        let mut simulation_work = PassParticleSimulationWork::default();
        for repetition in 0..options.repeats {
            let start = Instant::now();
            for frame in 0..options.frames {
                let stats = render((options.warmup + repetition * options.frames + frame) as i64)?;
                particle_work.add(&stats);
                simulation_work.add(&stats);
                for (&kind, &draws) in &stats.pass_draw_call_counts {
                    *pass_frames
                        .entry(kind.raw_value().to_string())
                        .or_insert(0_i64) += 1;
                    *pass_draws
                        .entry(kind.raw_value().to_string())
                        .or_insert(0_i64) += draws;
                }
                frame_samples.push(stats.cpu_frame_total_ns as f64 / 1000.0);
                encode_samples.push(stats.cpu_encode_ns as f64 / 1000.0);
                submit_samples.push(stats.cpu_submit_ns as f64 / 1000.0);
                if (frame + 1) % 3 == 0 {
                    finish()?;
                }
            }
            if options.frames % 3 != 0 {
                finish()?;
            }
            batches.push(start.elapsed().as_nanos() as f64 / options.frames as f64 / 1000.0);
        }
        Ok(PassBenchmarkResult {
            backend: name,
            device,
            cpu_frame: PassTimingDistribution::new(frame_samples),
            cpu_encode: PassTimingDistribution::new(encode_samples),
            cpu_submit: PassTimingDistribution::new(submit_samples),
            completed_batch: PassTimingDistribution::new(batches),
            pass_frames,
            pass_draws,
            particle_work,
            simulation_work,
        })
    }
}

struct AnimatedFixture;
impl Drop for AnimatedFixture {
    fn drop(&mut self) {
        AssetRegistry::shared().unregister_testing_mesh(2);
    }
}
enum BenchmarkRenderer {
    Grid(Box<NativeGridRenderer>),
    Scene(Box<NativeRenderer>),
}
impl BenchmarkRenderer {
    fn render(&mut self, packet: &RenderPacket) -> RhiResult<RenderFrameStats> {
        match self {
            Self::Grid(renderer) => {
                renderer.render_checked(packet)?;
                Ok(renderer.current_frame_stats())
            }
            Self::Scene(renderer) => {
                renderer.render_checked(packet)?;
                Ok(renderer.current_frame_stats())
            }
        }
    }
    fn color_texture(&self) -> Option<Texture> {
        match self {
            Self::Grid(renderer) => renderer.color_texture(),
            Self::Scene(renderer) => renderer.color_texture(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProbeScene {
    Grid,
    Mesh,
    Pbr,
    Animated,
    Post,
    Stylized,
    Particles,
    Simulation,
}
impl ProbeScene {
    fn name(self) -> &'static str {
        match self {
            Self::Grid => "grid",
            Self::Mesh => "mesh",
            Self::Pbr => "pbr",
            Self::Animated => "animated",
            Self::Post => "post",
            Self::Stylized => "stylized",
            Self::Particles => "particles",
            Self::Simulation => "simulation",
        }
    }
    fn parse(value: &str) -> RhiResult<Self> {
        match value {
            "grid" => Ok(Self::Grid),
            "mesh" => Ok(Self::Mesh),
            "pbr" => Ok(Self::Pbr),
            "animated" => Ok(Self::Animated),
            "post" => Ok(Self::Post),
            "stylized" => Ok(Self::Stylized),
            "particles" => Ok(Self::Particles),
            "simulation" => Ok(Self::Simulation),
            _ => Err(RhiError::invalid_argument(
                "choose grid, mesh, pbr, animated, post, stylized, particles or simulation scene",
            )),
        }
    }
    fn packet(self, size: RenderDrawableSize, frame: i64) -> RenderPacket {
        match self {
            Self::Grid => GridProbeScene::packet(size, frame, None),
            Self::Mesh => MeshProbeScene::packet(size, frame),
            Self::Pbr => PBRProbeScene::packet(size, frame),
            Self::Animated => AnimatedProbeScene::packet(size, frame),
            Self::Post => PostProbeScene::packet(size, frame),
            Self::Stylized => StylizedProbeScene::packet(size, frame),
            Self::Particles => ParticleProbeScene::packet(size, frame),
            Self::Simulation => ParticleSimulationProbeScene::packet(size, frame),
        }
    }
}
fn api_name(api: GraphicsApi) -> &'static str {
    match api {
        GraphicsApi::Metal => "metal",
        GraphicsApi::Vulkan => "vulkan",
        GraphicsApi::Dx12 => "dx12",
    }
}
struct PassBenchmarkOptions {
    scene: ProbeScene,
    size: RenderDrawableSize,
    frames: usize,
    warmup: usize,
    repeats: usize,
    backends: Vec<GraphicsApi>,
    output: PathBuf,
}
impl PassBenchmarkOptions {
    fn new(arguments: &[String]) -> RhiResult<Self> {
        let mut options = Self {
            scene: ProbeScene::Grid,
            size: RenderDrawableSize::new(1280, 720),
            frames: 180,
            warmup: 30,
            repeats: 3,
            backends: platform_default_backends(),
            output: PathBuf::from("/tmp/cove-native-grid"),
        };
        if !arguments.len().is_multiple_of(2) {
            return Err(RhiError::invalid_argument(
                "use --scene grid|mesh|pbr|animated|post|stylized|particles|simulation --width N --height N --frames N --warmup N --repeats N --backends metal|vulkan|dx12 --output DIR",
            ));
        }
        for pair in arguments.chunks_exact(2) {
            let value = &pair[1];
            match pair[0].as_str() {
                "--scene" => options.scene = ProbeScene::parse(value)?,
                "--output" => options.output = PathBuf::from(value),
                "--backends" => {
                    options.backends = value
                        .split(',')
                        .filter(|name| !name.is_empty())
                        .map(|name| match name {
                            "metal" => Ok(GraphicsApi::Metal),
                            "vulkan" => Ok(GraphicsApi::Vulkan),
                            "dx12" => Ok(GraphicsApi::Dx12),
                            _ => Err(RhiError::invalid_argument(format!(
                                "unknown backend {name}"
                            ))),
                        })
                        .collect::<RhiResult<_>>()?;
                    if options.backends.is_empty() {
                        return Err(RhiError::invalid_argument("choose a backend"));
                    }
                }
                "--width" | "--height" | "--frames" | "--warmup" | "--repeats" => {
                    let number = value
                        .parse::<i64>()
                        .ok()
                        .filter(|number| *number > 0 && *number <= 10000)
                        .ok_or_else(|| {
                            RhiError::invalid_argument("positive bounded benchmark values required")
                        })?;
                    match pair[0].as_str() {
                        "--width" => options.size.width = number as u32,
                        "--height" => options.size.height = number as u32,
                        "--frames" => options.frames = number as usize,
                        "--warmup" => options.warmup = number as usize,
                        _ => options.repeats = number as usize,
                    }
                }
                option => {
                    return Err(RhiError::invalid_argument(format!(
                        "unknown option {option}"
                    )));
                }
            }
        }
        Ok(options)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassTimingDistribution {
    pub p50_microseconds: f64,
    pub p95_microseconds: f64,
    pub sample_count: usize,
}
impl PassTimingDistribution {
    fn new(mut values: Vec<f64>) -> Self {
        assert!(!values.is_empty(), "timing distribution needs a sample");
        values.sort_by(f64::total_cmp);
        let sample_count = values.len();
        Self {
            p50_microseconds: values
                [((sample_count as f64 * 0.50).ceil() as usize).saturating_sub(1)],
            p95_microseconds: values
                [((sample_count as f64 * 0.95).ceil() as usize).saturating_sub(1)],
            sample_count,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassBenchmarkResult {
    pub backend: String,
    pub device: String,
    pub cpu_frame: PassTimingDistribution,
    pub cpu_encode: PassTimingDistribution,
    pub cpu_submit: PassTimingDistribution,
    pub completed_batch: PassTimingDistribution,
    pub pass_frames: BTreeMap<String, i64>,
    pub pass_draws: BTreeMap<String, i64>,
    pub particle_work: PassParticleWork,
    pub simulation_work: PassParticleSimulationWork,
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassParticleWork {
    pub candidates: i64,
    pub batches: i64,
    pub dispatch_workgroups: i64,
    pub indirect_draws: i64,
}
impl PassParticleWork {
    fn add(&mut self, stats: &RenderFrameStats) {
        self.candidates += stats.gpu_particle_cull_candidate_count;
        self.batches += stats.gpu_particle_cull_batch_count;
        self.dispatch_workgroups += stats.gpu_particle_cull_dispatch_workgroups;
        self.indirect_draws += stats.gpu_particle_indirect_draw_count;
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassParticleSimulationWork {
    pub batches: i64,
    pub particles: i64,
    pub simulation_workgroups: i64,
    pub sort_passes: i64,
    pub sort_items: i64,
    pub sort_padded_items: i64,
    pub sort_workgroups: i64,
    pub instance_workgroups: i64,
    pub render_instances: i64,
    pub event_capacity: i64,
    pub event_bytes: i64,
}
impl PassParticleSimulationWork {
    fn add(&mut self, stats: &RenderFrameStats) {
        self.batches += stats.gpu_particle_simulation_batch_count;
        self.particles += stats.gpu_particle_simulation_particle_count;
        self.simulation_workgroups += stats.gpu_particle_simulation_dispatch_workgroups;
        self.sort_passes += stats.gpu_particle_sort_pass_count;
        self.sort_items += stats.gpu_particle_sort_item_count;
        self.sort_padded_items += stats.gpu_particle_sort_padded_item_count;
        self.sort_workgroups += stats.gpu_particle_sort_dispatch_workgroups;
        self.instance_workgroups += stats.gpu_particle_instance_dispatch_workgroups;
        self.render_instances += stats.gpu_particle_render_instance_count;
        self.event_capacity += stats.gpu_particle_simulation_event_capacity;
        self.event_bytes += stats.gpu_particle_simulation_event_buffer_bytes;
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PassBenchmarkReport<'a> {
    scene: &'static str,
    width: u32,
    height: u32,
    frames: usize,
    warmup: usize,
    repeats: usize,
    results: &'a [PassBenchmarkResult],
    image_differences: &'a BTreeMap<String, GridImageDifference>,
    environment: PassBenchmarkEnvironment,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PassBenchmarkEnvironment {
    operating_system: String,
    measured_at: String,
    build_configuration: &'static str,
    shader_compiler: &'static str,
    validation_enabled: bool,
    frames_per_completed_batch: usize,
    timing_method: &'static str,
}
impl PassBenchmarkEnvironment {
    fn new() -> std::io::Result<Self> {
        let timestamp = match SystemTime::now().duration_since(UNIX_EPOCH) {
            Ok(duration) => duration.as_secs_f64(),
            Err(error) => -error.duration().as_secs_f64(),
        };
        Ok(Self {
            operating_system: operating_system()?,
            measured_at: cove_logging::iso8601(timestamp.floor()).replace(".000Z", "Z"),
            build_configuration: if cfg!(debug_assertions) {
                "debug"
            } else {
                "release"
            },
            shader_compiler: "Slang 2026.19",
            validation_enabled: false,
            frames_per_completed_batch: 3,
            timing_method: "CPU durations and three-frame batch completion; no GPU timestamps or presentation",
        })
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn operating_system() -> std::io::Result<String> {
    fn sysctl_string(name: &std::ffi::CStr) -> std::io::Result<String> {
        let mut length = 0;
        // SAFETY: both calls use a NUL-terminated read-only key. The first
        // obtains the allocation size and the second writes only that range.
        if unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                std::ptr::null_mut(),
                &mut length,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error());
        }
        let mut bytes = vec![0_u8; length];
        // SAFETY: bytes is writable for length bytes, with no new value supplied.
        if unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                bytes.as_mut_ptr().cast(),
                &mut length,
                std::ptr::null_mut(),
                0,
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error());
        }
        let text = std::ffi::CStr::from_bytes_until_nul(&bytes)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
        Ok(text.to_string_lossy().into_owned())
    }
    Ok(format!(
        "Version {} (Build {})",
        sysctl_string(c"kern.osproductversion")?,
        sysctl_string(c"kern.osversion")?
    ))
}
#[cfg(all(unix, not(any(target_os = "macos", target_os = "ios"))))]
fn operating_system() -> std::io::Result<String> {
    let mut information = std::mem::MaybeUninit::<libc::utsname>::uninit();
    // SAFETY: uname initializes this properly sized output on success.
    if unsafe { libc::uname(information.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a successful uname initializes every field.
    let information = unsafe { information.assume_init() };
    // SAFETY: uname guarantees these fixed C arrays are NUL-terminated.
    let name = unsafe { std::ffi::CStr::from_ptr(information.sysname.as_ptr()) };
    // SAFETY: release is another NUL-terminated field initialized by uname.
    let release = unsafe { std::ffi::CStr::from_ptr(information.release.as_ptr()) };
    // SAFETY: version is another NUL-terminated field initialized by uname.
    let version = unsafe { std::ffi::CStr::from_ptr(information.version.as_ptr()) };
    Ok(format!(
        "{} {} {}",
        name.to_string_lossy(),
        release.to_string_lossy(),
        version.to_string_lossy()
    ))
}
#[cfg(windows)]
fn operating_system() -> std::io::Result<String> {
    #[repr(C)]
    struct VersionInfo {
        size: u32,
        major: u32,
        minor: u32,
        build: u32,
        platform: u32,
        service_pack: [u16; 128],
    }
    const _: () = assert!(
        std::mem::size_of::<VersionInfo>() == 276 && std::mem::align_of::<VersionInfo>() == 4
    );
    #[link(name = "ntdll")]
    unsafe extern "system" {
        #[link_name = "RtlGetVersion"]
        fn rtl_get_version(information: *mut VersionInfo) -> i32;
    }
    let mut version = VersionInfo {
        size: std::mem::size_of::<VersionInfo>() as u32,
        major: 0,
        minor: 0,
        build: 0,
        platform: 0,
        service_pack: [0; 128],
    };
    // SAFETY: the output is the OSVERSIONINFOW layout expected by RtlGetVersion.
    let status = unsafe { rtl_get_version(&mut version) };
    if status < 0 {
        return Err(std::io::Error::other(format!(
            "RtlGetVersion failed ({status:#x})"
        )));
    }
    let length = version
        .service_pack
        .iter()
        .position(|&unit| unit == 0)
        .unwrap_or(version.service_pack.len());
    let service_pack = String::from_utf16_lossy(&version.service_pack[..length]);
    let suffix = if service_pack.is_empty() {
        String::new()
    } else {
        format!(" {service_pack}")
    };
    Ok(format!(
        "Version {}.{}.{} (Build {}){suffix}",
        version.major, version.minor, version.build, version.build
    ))
}
#[cfg(not(any(unix, windows)))]
fn operating_system() -> std::io::Result<String> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "operating system version is unavailable on this target",
    ))
}

/// Shared command setup keeps both executable entries on the same logging path.
pub fn run_command(
    mut arguments: Vec<String>,
    default_scene: Option<&str>,
    failure_label: &str,
) -> std::process::ExitCode {
    struct FlushLogs;
    impl Drop for FlushLogs {
        fn drop(&mut self) {
            LogSystem::flush();
        }
    }
    let _flush = FlushLogs;
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let mut configuration = LoggingConfiguration::default();
        configuration.apply_environment(&std::env::vars().collect())?;
        LogSystem::bootstrap(None, configuration, None)?;
        if let Some(scene) = default_scene
            && !arguments.iter().any(|argument| argument == "--scene")
        {
            arguments.splice(0..0, ["--scene".to_string(), scene.to_string()]);
        }
        NativePassBenchmark::run(&arguments)?;
        Ok(())
    })();
    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            LogSystem::logger("com.cove.tools").log(&LogEvent::new(
                Level::Error,
                format!("{failure_label}: {error}"),
            ));
            std::process::ExitCode::FAILURE
        }
    }
}
