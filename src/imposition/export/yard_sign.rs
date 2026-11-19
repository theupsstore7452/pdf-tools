use super::{
    create_source_form, Content, Dictionary, LoDocument, Object, Operation, Stream,
    MAX_EXPORT_DECODED_CONTENT_BYTES, PT_PER_IN,
};
use crate::{
    adapters::BoundedBytes,
    error::{AppError, AppResult},
    MAX_SOURCE_PDF_PAGES,
};
use lopdf::dictionary;

const BLEED: f64 = 0.25 * PT_PER_IN;
enum Mode {
    Fit,
    Fill,
    Stretch,
}
pub(crate) struct YardSign {
    width: f64,
    height: f64,
    mode: Mode,
}

impl YardSign {
    pub(crate) fn parse(width: &str, height: &str, mode: &str) -> AppResult<Self> {
        fn points(name: &str, value: &str) -> AppResult<f64> {
            // Standard PDF pages use at most 14,400 points per side, including bleed.
            value
                .trim()
                .parse::<f64>()
                .ok()
                .map(|v| v * PT_PER_IN)
                .filter(|v| {
                    *v > 0.0 && *v + 2.0 * BLEED <= 14400.0 && ((*v + BLEED) as f32) > BLEED as f32
                })
                .ok_or_else(|| {
                    AppError::bad_request(format!(
                        "{name} must be a positive finished size up to 199.5 inches"
                    ))
                })
        }
        Ok(Self {
            width: points("width", width)?,
            height: points("height", height)?,
            mode: match mode {
                "fit" => Mode::Fit,
                "fill" => Mode::Fill,
                "stretch" => Mode::Stretch,
                _ => return Err(AppError::bad_request("mode must be fit, fill, or stretch")),
            },
        })
    }

    pub(crate) fn generate(&self, source: &[u8], limit: Option<usize>) -> AppResult<Vec<u8>> {
        self.generate_pages(source, limit, None)
    }

    pub(crate) fn generate_pages(
        &self,
        source: &[u8],
        limit: Option<usize>,
        selected: Option<u32>,
    ) -> AppResult<Vec<u8>> {
        let mut doc = LoDocument::load_mem(source)
            .map_err(|e| AppError::bad_request_cause("could not read yard sign source", e))?;
        let pages = doc.get_pages();
        if pages.is_empty() || pages.len() > MAX_SOURCE_PDF_PAGES {
            return Err(AppError::bad_request("invalid yard sign source page count"));
        }
        let (w, h) = (self.width + 2.0 * BLEED, self.height + 2.0 * BLEED);
        let media = vec![0.into(), 0.into(), w.into(), h.into()];
        let trim = vec![
            BLEED.into(),
            BLEED.into(),
            (w - BLEED).into(),
            (h - BLEED).into(),
        ];
        let mut budget = MAX_EXPORT_DECODED_CONTENT_BYTES;
        let selected_id = selected
            .map(|number| {
                pages
                    .get(&number)
                    .copied()
                    .ok_or_else(|| AppError::bad_request("proof page is out of range"))
            })
            .transpose()?;
        for id in pages
            .into_values()
            .filter(|id| selected_id.is_none_or(|selected| selected == *id))
        {
            let form = create_source_form(&mut doc, id, &mut budget, None)?;
            let (sw, sh) = (form.size.width * PT_PER_IN, form.size.height * PT_PER_IN);
            let (sx, sy) = (w / sw, h / sh);
            let (sx, sy) = match self.mode {
                Mode::Fit => (sx.min(sy), sx.min(sy)),
                Mode::Fill => (sx.max(sy), sx.max(sy)),
                Mode::Stretch => (sx, sy),
            };
            let matrix = [sx, 0.0, 0.0, sy, (w - sw * sx) / 2.0, (h - sh * sy) / 2.0];
            if !matrix.iter().all(|value| (*value as f32).is_finite()) {
                return Err(AppError::bad_request(
                    "source page cannot be scaled to the requested size",
                ));
            }
            let content = Content {
                operations: vec![
                    Operation::new("q", vec![]),
                    Operation::new("cm", matrix.into_iter().map(Object::from).collect()),
                    Operation::new("Do", vec![Object::Name(b"Artwork".to_vec())]),
                    Operation::new("Q", vec![]),
                ],
            }
            .encode()
            .map_err(|e| AppError::internal_cause("could not encode yard sign page", e))?;
            let stream = doc.add_object(Stream::new(Dictionary::new(), content));
            let page = doc
                .get_dictionary_mut(id)
                .map_err(|e| AppError::bad_request_cause("invalid source page", e))?;
            let parent = page
                .get(b"Parent")
                .map_err(|e| AppError::bad_request_cause("missing page parent", e))?
                .clone();
            *page = dictionary! {
                "Type" => "Page", "Parent" => parent,
                "MediaBox" => media.clone(), "CropBox" => media.clone(),
                "BleedBox" => media.clone(), "TrimBox" => trim.clone(),
                "Rotate" => 0, "UserUnit" => 1,
                "Resources" => dictionary! { "XObject" => dictionary! { "Artwork" => form.object_id } },
                "Contents" => stream,
            };
        }
        if let Some(id) = selected_id {
            // Resolve inherited artwork geometry/resources before detaching the page.
            let root = doc.add_object(dictionary! { "Type" => "Pages", "Count" => 1, "Kids" => vec![Object::Reference(id)] });
            doc.get_dictionary_mut(id)
                .map_err(|e| AppError::bad_request_cause("invalid source page", e))?
                .set("Parent", root);
            let catalog = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => root });
            doc.trailer.set("Root", catalog);
        }
        doc.prune_objects();
        let mut out = BoundedBytes::new(source.len(), limit);
        let result = doc.save_to(&mut out);
        out.finish(result, "could not save yard sign PDF")
    }
}
