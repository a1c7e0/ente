//! Human body indexing is independent of the face and CLIP pipelines.
use std::sync::{Mutex, PoisonError};

use ente_assets::{Asset, AssetFile, AssetStore};
use ente_image::decode::{decode_image_from_bytes, decode_image_from_path};
use image::{RgbImage, imageops::FilterType};
use once_cell::sync::Lazy;

use crate::{
    assets,
    error::{MlError, MlResult},
    indexing::ImageSource,
    models::Model,
    onnx::{self, ExecutionMode, OnnxSession, PreparedF32Input},
    postprocess::{NmsDetection, greedy_non_max_suppression, l2_normalize},
    preprocess::{self, YoloInput},
    types::Dimensions,
};

pub const BODY_MODEL: &str = "osnet-ain-x1.0-msmt17-v1";
const EMBEDDER_FILE: &str = "osnet_ain_x1_0_msmt17.onnx";
const DETECTOR_FILE: &str = "yolov5s_object_fp16.onnx";
const EMBEDDING_DIMENSIONS: usize = 512;
// Bound memory use while using the model's dynamic batch dimension.
const EMBEDDING_BATCH: usize = 16;

#[derive(Clone, Debug)]
pub struct BodyModelPaths {
    pub detector: String,
    pub embedder: String,
}

#[derive(Clone, Debug)]
pub struct BodyDetection {
    pub body_id: String,
    /// Coordinates in the decoded, EXIF-oriented image, normalized to [0, 1].
    pub box_xyxy: [f32; 4],
    pub score: f32,
    pub embedding: Vec<f32>,
}

#[derive(Clone, Debug)]
pub struct BodyIndex {
    pub dimensions: Dimensions,
    pub detections: Vec<BodyDetection>,
}

impl NmsDetection for BodyDetection {
    fn score(&self) -> f32 {
        self.score
    }
    fn box_xyxy(&self) -> &[f32; 4] {
        &self.box_xyxy
    }
    fn same_class(&self, _: &Self) -> bool {
        true
    }
}

static DETECTOR: Lazy<Mutex<Option<OnnxSession>>> = Lazy::new(|| Mutex::new(None));
static EMBEDDER: Lazy<Mutex<Option<OnnxSession>>> = Lazy::new(|| Mutex::new(None));

pub fn model_assets() -> Vec<Asset> {
    #[expect(clippy::expect_used, reason = "The body model catalog has a valid key and checksum")]
    let embedder = Asset::files(
        vec!["models".into(), BODY_MODEL.into()],
        vec![AssetFile {
            name: EMBEDDER_FILE.into(),
            url: "https://github.com/a1c7e0/ente/releases/download/body-reid-models-v1/osnet_ain_x1_0_msmt17.onnx".into(),
            size: 8_742_433,
            sha256: "59153d81aa87a215d15bdebff5ce87f676a9507a1c0eb1e2d1ddced8e0018864".into(),
        }],
    ).expect("valid body model catalog");
    vec![assets::model_asset(Model::PetBodyDetection), embedder]
}

pub async fn ensure_models(
    store: &AssetStore,
) -> Result<BodyModelPaths, ente_assets::download::Error> {
    let models = model_assets();
    store.download(&models, |_| {}, Default::default()).await?;
    #[expect(
        clippy::expect_used,
        reason = "Filenames belong to the built-in body assets"
    )]
    Ok(BodyModelPaths {
        detector: store
            .file_path(&models[0], DETECTOR_FILE)
            .expect("body detector")
            .to_string_lossy()
            .into_owned(),
        embedder: store
            .file_path(&models[1], EMBEDDER_FILE)
            .expect("body embedder")
            .to_string_lossy()
            .into_owned(),
    })
}

pub fn release_runtime() {
    for model in [&*DETECTOR, &*EMBEDDER] {
        let mut session = model.lock().unwrap_or_else(PoisonError::into_inner);
        *session = None;
    }
}

fn run_model<const N: usize>(
    model: &Mutex<Option<OnnxSession>>,
    path: &str,
    namespace: &'static str,
    input: &PreparedF32Input,
    shape: [i64; N],
) -> MlResult<(Vec<i64>, Vec<f32>)> {
    let mut guard = model.lock().unwrap_or_else(PoisonError::into_inner);
    if guard.as_ref().is_none_or(|s| s.model_path() != path) {
        *guard = Some(OnnxSession::new(path, namespace, ExecutionMode::CpuOnly));
    }
    let session = guard
        .as_mut()
        .ok_or_else(|| MlError::InvalidRequest("missing body model".into()))?;
    session
        .run(|handle| onnx::run_f32(handle, input, shape))
        .map(|(output, _)| output)
}

pub fn analyze(file_id: i64, source: ImageSource, paths: &BodyModelPaths) -> MlResult<BodyIndex> {
    let decoded = match source {
        ImageSource::Path(path) => decode_image_from_path(&path)?,
        ImageSource::Bytes(bytes) => decode_image_from_bytes(&bytes)?,
    };
    let input = preprocess::preprocess_yolo(&decoded)?;
    let (shape, output) = run_model(
        &DETECTOR,
        &paths.detector,
        "human-body-detection",
        &input.tensor,
        [1, 3, 640, 640],
    )?;
    let mut detections = detect(file_id, &shape, &output, &input)?;
    let image = RgbImage::from_raw(
        decoded.dimensions.width,
        decoded.dimensions.height,
        decoded.rgb,
    )
    .ok_or_else(|| MlError::Image("invalid RGB body image".into()))?;
    embed(&image, &mut detections, paths)?;
    Ok(BodyIndex {
        dimensions: decoded.dimensions,
        detections,
    })
}

fn embed(
    image: &RgbImage,
    detections: &mut [BodyDetection],
    paths: &BodyModelPaths,
) -> MlResult<()> {
    const CROP_FLOATS: usize = 3 * 256 * 128;
    for batch in detections.chunks_mut(EMBEDDING_BATCH) {
        let mut values = vec![0.0; batch.len() * CROP_FLOATS];
        for (i, detection) in batch.iter().enumerate() {
            values[i * CROP_FLOATS..(i + 1) * CROP_FLOATS]
                .copy_from_slice(&crop_tensor(image, &detection.box_xyxy)?);
        }
        let tensor = PreparedF32Input::new(values);
        let (shape, output) = run_model(
            &EMBEDDER,
            &paths.embedder,
            "human-body-embedding",
            &tensor,
            [batch.len() as i64, 3, 256, 128],
        )?;
        if shape != [batch.len() as i64, EMBEDDING_DIMENSIONS as i64]
            || output.len() != batch.len() * EMBEDDING_DIMENSIONS
        {
            return Err(MlError::Postprocess(format!(
                "unexpected body embedding shape: {shape:?}"
            )));
        }
        for (i, detection) in batch.iter_mut().enumerate() {
            let mut embedding =
                output[i * EMBEDDING_DIMENSIONS..(i + 1) * EMBEDDING_DIMENSIONS].to_vec();
            if embedding.iter().map(|v| v * v).sum::<f32>() < 1e-12 {
                return Err(MlError::Postprocess("body embedding has zero norm".into()));
            }
            l2_normalize(&mut embedding, 1e-12);
            detection.embedding = embedding;
        }
    }
    Ok(())
}

fn detect(
    file_id: i64,
    shape: &[i64],
    output: &[f32],
    input: &YoloInput,
) -> MlResult<Vec<BodyDetection>> {
    if shape.len() != 3 || shape[0] != 1 || shape[2] != 85 || output.len() != shape[1] as usize * 85
    {
        return Err(MlError::Postprocess(format!(
            "unexpected body detector shape: {shape:?}"
        )));
    }
    let mut detections = Vec::new();
    for row in output.as_chunks::<85>().0 {
        let score = row[4] * row[5];
        if score < 0.4 || row[6..].iter().any(|s| *s > row[5]) {
            continue;
        }
        let mut bbox = [
            (row[0] - row[2] / 2.0) / 640.0,
            (row[1] - row[3] / 2.0) / 640.0,
            (row[0] + row[2] / 2.0) / 640.0,
            (row[1] + row[3] / 2.0) / 640.0,
        ];
        input.correct_box(&mut bbox);
        // correct_box skips identity geometry, including edge detections.
        bbox = bbox.map(|v| v.clamp(0.0, 1.0));
        if bbox[2] <= bbox[0] || bbox[3] - bbox[1] < 0.12 {
            continue;
        }
        let body_id = format!("body:{}", crate::types::to_face_id(file_id, bbox));
        detections.push(BodyDetection {
            body_id,
            box_xyxy: bbox,
            score,
            embedding: Vec::new(),
        });
    }
    Ok(greedy_non_max_suppression(detections, 0.5))
}

fn crop_tensor(image: &RgbImage, bbox: &[f32; 4]) -> MlResult<Vec<f32>> {
    let (w, h) = image.dimensions();
    let x1 = (bbox[0] * w as f32).floor().clamp(0.0, (w - 1) as f32) as u32;
    let y1 = (bbox[1] * h as f32).floor().clamp(0.0, (h - 1) as f32) as u32;
    let x2 = (bbox[2] * w as f32).ceil().clamp((x1 + 1) as f32, w as f32) as u32;
    let y2 = (bbox[3] * h as f32).ceil().clamp((y1 + 1) as f32, h as f32) as u32;
    let crop = image::imageops::crop_imm(image, x1, y1, x2 - x1, y2 - y1).to_image();
    let resized = image::imageops::resize(&crop, 128, 256, FilterType::Triangle);
    let mut data = vec![0.0; 3 * 128 * 256];
    let mean = [0.485, 0.456, 0.406];
    let std = [0.229, 0.224, 0.225];
    for (i, pixel) in resized.pixels().enumerate() {
        for c in 0..3 {
            data[c * 128 * 256 + i] = (pixel[c] as f32 / 255.0 - mean[c]) / std[c];
        }
    }
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input() -> YoloInput {
        YoloInput {
            tensor: PreparedF32Input::new(vec![]),
            scaled_width: 640,
            scaled_height: 320,
            pad_left: 0,
            pad_top: 160,
        }
    }

    fn person_row(x: f32, score: f32) -> Vec<f32> {
        let mut row = vec![0.0; 85];
        row[..6].copy_from_slice(&[x, 320.0, 100.0, 200.0, 1.0, score]);
        row
    }

    #[test]
    fn detector_corrects_letterbox_and_suppresses_duplicate_people() {
        let output = [
            person_row(200.0, 0.9),
            person_row(202.0, 0.8),
            person_row(500.0, 0.85),
        ]
        .concat();
        let bodies = detect(7, &[1, 3, 85], &output, &input()).unwrap();
        assert_eq!(bodies.len(), 2);
        assert!(bodies[0].body_id.starts_with("body:7_"));
        assert!((bodies[0].box_xyxy[1] - 0.1875).abs() < 1e-6);
        assert!((bodies[0].box_xyxy[3] - 0.8125).abs() < 1e-6);
    }

    #[test]
    fn detector_rejects_other_classes_small_boxes_and_wrong_outputs() {
        let mut cat = person_row(200.0, 0.8);
        cat[20] = 0.9;
        let mut tiny = person_row(500.0, 0.9);
        tiny[3] = 10.0;
        assert!(
            detect(1, &[1, 2, 85], &[cat, tiny].concat(), &input())
                .unwrap()
                .is_empty()
        );
        assert!(detect(1, &[1, 84, 10], &[0.0; 840], &input()).is_err());
    }

    #[test]
    fn edge_boxes_are_normalized_even_without_letterbox_padding() {
        let input = YoloInput {
            tensor: PreparedF32Input::new(vec![]),
            scaled_width: 640,
            scaled_height: 640,
            pad_left: 0,
            pad_top: 0,
        };
        let bodies = detect(1, &[1, 1, 85], &person_row(5.0, 0.9), &input).unwrap();
        assert_eq!(bodies.len(), 1);
        assert_eq!(bodies[0].box_xyxy[0], 0.0);
        assert!(bodies[0].box_xyxy.iter().all(|v| (0.0..=1.0).contains(v)));
    }

    #[cfg(feature = "ml-assets")]
    #[tokio::test]
    async fn downloaded_models_match_the_body_tensor_contract() {
        let directory = tempfile::tempdir().unwrap();
        let root = std::env::var_os("ENTE_BODY_TEST_ASSETS")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| directory.path().to_path_buf());
        let paths = ensure_models(&AssetStore::new(root)).await.unwrap();
        let decoded = crate::types::DecodedImage {
            dimensions: Dimensions {
                width: 640,
                height: 640,
            },
            rgb: vec![128; 640 * 640 * 3],
        };
        let input = preprocess::preprocess_yolo(&decoded).unwrap();
        let (shape, output) = run_model(
            &DETECTOR,
            &paths.detector,
            "human-body-detection",
            &input.tensor,
            [1, 3, 640, 640],
        )
        .unwrap();
        assert!(detect(1, &shape, &output, &input).is_ok());
        let image = RgbImage::from_raw(640, 640, decoded.rgb).unwrap();
        // Exercise batches of 16 and 1, preserving the real crop count/order.
        let mut bodies = vec![
            BodyDetection {
                body_id: "body:1_test".into(),
                box_xyxy: [0.1, 0.1, 0.9, 0.9],
                score: 0.9,
                embedding: vec![]
            };
            EMBEDDING_BATCH + 1
        ];
        embed(&image, &mut bodies, &paths).unwrap();
        assert_eq!(bodies.len(), EMBEDDING_BATCH + 1);
        for body in &bodies {
            assert_eq!(body.embedding.len(), 512);
            assert!(body.embedding.iter().all(|v| v.is_finite()));
            assert!((body.embedding.iter().map(|v| v * v).sum::<f32>() - 1.0).abs() < 1e-5);
            assert!(
                body.embedding
                    .iter()
                    .zip(&bodies[0].embedding)
                    .all(|(a, b)| (a - b).abs() < 1e-5)
            );
        }
        release_runtime();
    }
}
