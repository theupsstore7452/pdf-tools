//! Shared page organization for every workflow, independent of impose geometry.
use super::state::OperationPermit;
use crate::{
    adapters::{
        require_pdfs, stage_impose_multipart, FileDownload, FormData, StagedImposeForm, UploadFile,
    },
    documents,
    error::{AppError, AppResult},
    progress::{report, ProgressCallback},
    AppState,
};
use axum::{
    extract::{Multipart, Path, State},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use std::sync::Arc;

pub(crate) async fn prepare(
    State(state): State<Arc<AppState>>,
    multipart: Multipart,
) -> AppResult<Response> {
    let staged = stage_impose_multipart(
        multipart,
        &state.impose_staging_dir(),
        state.impose_upload_limits(),
    )
    .await?;
    let permit = state.admit_operation()?;
    super::jobs::create_staged_prepare(state, staged, permit, true)
}

pub(crate) async fn prepare_staged(
    state: Arc<AppState>,
    staged: StagedImposeForm,
    permit: OperationPermit,
    progress: Option<ProgressCallback>,
) -> AppResult<FileDownload> {
    if staged
        .files
        .iter()
        .any(|file| !matches!(file.is_pdf(), Ok(true)))
    {
        return super::gang_up::prepare_staged_source(state, staged, permit, progress).await;
    }
    let filename = staged
        .files
        .first()
        .map(|f| f.filename().to_string())
        .ok_or_else(|| AppError::bad_request("Choose a PDF."))?;
    let max = state.max_download_bytes();
    let store = state.source_session_store();
    let pdfium = state.pdfium();
    let progress_cpu = progress.clone();
    let (id, count) = state
        .run_pdfium(permit, move || {
            report(&progress_cpu, 30, "Preparing page thumbnails")?;
            if staged.files.len() == 1 {
                let document = documents::load_pdf_path(&pdfium, staged.files[0].path())?;
                let count = documents::page_count(document.pages().len())?;
                if count == 0 || count > crate::MAX_SOURCE_PDF_PAGES {
                    return Err(AppError::bad_request("Invalid PDF page count."));
                }
                Ok((
                    store.create_from_path(&filename, staged.files[0].path())?,
                    count,
                ))
            } else {
                let bytes =
                    documents::merge_staged_pdfs(&pdfium, &staged.files, max, progress_cpu)?;
                let document = documents::load_pdf(&pdfium, bytes.clone().into())?;
                let count = documents::page_count(document.pages().len())?;
                Ok((
                    store.create(&UploadFile {
                        filename,
                        bytes: bytes.into(),
                    })?,
                    count,
                ))
            }
        })
        .await?;
    let result = FileDownload::bounded(
        "application/json",
        "page-workspace.json",
        serde_json::to_vec(&serde_json::json!({"sourceId":id,"pageCount":count}))
            .map_err(|e| AppError::internal_cause("Could not encode page workspace.", e))?,
        max,
    );
    if result.is_err() {
        let _ = state.source_session_store().delete(&id);
    }
    result
}

pub(crate) async fn thumbnails(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ThumbnailRequest>,
) -> AppResult<Response> {
    let permit = state.admit_operation()?;
    let source = state.source_session_store().load_path(&id)?;
    let pdfium = state.pdfium();
    let images = state
        .run_pdfium(permit.clone(), move || {
            documents::raster_page_thumbnails(&pdfium, &source.path, request.page_numbers)
        })
        .await?;
    let bytes = state
        .run_cpu(permit, move || documents::encode_preview_batch(images))
        .await?;
    crate::adapters::validate_download_size(bytes.len(), state.max_download_bytes())?;
    Ok((
        [
            (
                axum::http::header::CONTENT_TYPE,
                "application/vnd.pdf-tools.preview-batch",
            ),
            (axum::http::header::CACHE_CONTROL, "no-store"),
        ],
        bytes,
    )
        .into_response())
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ThumbnailRequest {
    page_numbers: Vec<usize>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OrderRequest {
    page_order: Vec<usize>,
}

pub(crate) async fn order_source(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<OrderRequest>,
) -> AppResult<Response> {
    let permit = state.admit_operation()?;
    Ok(ordered_source(state, id, request.page_order, permit, None)
        .await?
        .into_response())
}

pub(crate) async fn ordered_source(
    state: Arc<AppState>,
    id: String,
    order: Vec<usize>,
    permit: OperationPermit,
    progress: Option<ProgressCallback>,
) -> AppResult<FileDownload> {
    let source = state.source_session_store().load_path(&id)?;
    let max = state.max_download_bytes();
    let file = state
        .run_cpu(permit.clone(), move || {
            let bytes = std::fs::read(&source.path)
                .map_err(|e| AppError::internal_cause("Could not read source pages.", e))?;
            documents::reorder_pdf(
                UploadFile {
                    filename: source.filename.clone(),
                    bytes: bytes.into(),
                },
                &order,
                max,
            )
        })
        .await?;
    super::gang_up::prepare_source_form(
        state,
        FormData {
            files: vec![file],
            fields: vec![],
        },
        permit,
        progress,
    )
    .await
}

pub(crate) async fn ordered_form(
    state: Arc<AppState>,
    mut form: FormData,
    permit: OperationPermit,
    progress: Option<ProgressCallback>,
) -> AppResult<FormData> {
    let Some(raw) = form.field("pageOrder") else {
        return Ok(form);
    };
    let order = documents::parse_page_order(raw)?;
    form.fields.retain(|(key, _)| key != "pageOrder");
    if form
        .files
        .iter()
        .all(|file| !crate::adapters::is_pdf(&file.bytes))
    {
        documents::validate_page_order(&order, form.files.len())?;
        form.files = order
            .into_iter()
            .map(|n| form.files[n - 1].clone())
            .collect();
        return Ok(form);
    }
    require_pdfs(
        &form.files,
        "Page ordering requires PDF pages or images of the same type.",
    )?;
    let files = form.files;
    let filename = files
        .first()
        .map(|f| f.filename.clone())
        .ok_or_else(|| AppError::bad_request("Choose a PDF."))?;
    let pdfium = state.pdfium();
    let max = state.max_download_bytes();
    let file = state
        .run_pdfium(permit, move || {
            report(&progress, 25, "Applying page order")?;
            let file = if files.len() == 1 {
                files
                    .into_iter()
                    .next()
                    .ok_or_else(|| AppError::bad_request("Choose a PDF."))?
            } else {
                UploadFile {
                    filename,
                    bytes: documents::merge_pdfs(&pdfium, files, max, progress.clone())?.into(),
                }
            };
            documents::reorder_pdf(file, &order, max)
        })
        .await?;
    Ok(FormData {
        files: vec![file],
        fields: form.fields,
    })
}
