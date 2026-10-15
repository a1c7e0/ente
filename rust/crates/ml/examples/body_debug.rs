//! Print face/body boxes from the production Rust pipelines without saving ML data.
#[expect(dead_code, reason = "Only the shared runtime loader is needed here")]
#[path = "../tests/support/mod.rs"]
mod support;

use std::time::Instant;

use anyhow::{Context, Result, bail};
use ente_assets::AssetStore;
use ente_ml::{assets, body, indexing};
use serde_json::json;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let Some(assets_dir) = args.next() else {
        bail!("usage: body_debug <assets-dir> <image> [image ...]");
    };
    let images: Vec<_> = args.collect();
    if images.is_empty() {
        bail!("provide at least one image");
    }
    support::ml_indexing::load_onnx_runtime().await?;
    let store = AssetStore::new(&assets_dir);
    let body_paths = body::ensure_models(&store).await?;
    let face_paths = assets::ensure_indexing_models(
        &store,
        std::path::Path::new(&assets_dir),
        true,
        false,
        false,
    )
    .await?;
    for (file_id, path) in images.into_iter().enumerate() {
        let start = Instant::now();
        let faces = indexing::analyze_image(indexing::AnalyzeImageRequest {
            file_id: file_id as i64,
            source: indexing::ImageSource::Path(path.clone()),
            run_faces: true,
            run_clip: false,
            run_pets: false,
            generate_face_crops: false,
            model_paths: face_paths.clone(),
        })
        .with_context(|| format!("face inference: {path}"))?;
        let bodies = body::analyze(
            file_id as i64,
            indexing::ImageSource::Path(path.clone()),
            &body_paths,
        )
        .with_context(|| format!("body inference: {path}"))?;
        println!(
            "{}",
            json!({
                "path": path,
                "width": bodies.dimensions.width,
                "height": bodies.dimensions.height,
                "model": body::BODY_MODEL,
                "elapsed_ms": start.elapsed().as_millis(),
                "faces": faces.faces.unwrap_or_default().iter().map(|face| json!({
                    "box": face.detection.box_xyxy,
                    "score": face.detection.score,
                })).collect::<Vec<_>>(),
                "bodies": bodies.detections.iter().map(|d| json!({
                    "box": d.box_xyxy,
                    "score": d.score,
                    "embedding_dimensions": d.embedding.len(),
                    "embedding_norm": d.embedding.iter().map(|v| v * v).sum::<f32>().sqrt(),
                })).collect::<Vec<_>>(),
            })
        );
    }
    indexing::release_ml_runtime();
    body::release_runtime();
    Ok(())
}
